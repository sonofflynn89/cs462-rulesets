ruleset gossip {
    meta {
        use module io.picolabs.subscription alias subs
        use module temperature_store
        shares health_check, peer_in_most_need, first_needed_message, get_unseen_messages, scheduled_heartbeats
        provides health_check,  peer_in_most_need, first_needed_message, get_unseen_messages, scheduled_heartbeats
        
    }

    global {
        default_interval = 20 // 20 seconds
        
        //////////////////////
        // Debug Functions
        //////////////////////
        health_check = function() {
            {
                "gossip_id": ent:gossip_id,
                "sequence": ent:sequence_number,
                "logs": ent:temperature_logs,
                "summaries": ent:peer_summaries,
                "interval": ent:gossip_interval,
                "sub_to_gossip": ent:sub_to_gossip,
                "my_wellKnown": subs:wellKnown_Rx(){"id"}
            }
        }
        
        ///////////////////////
        // Gossip Functions
        ///////////////////////
        temperature_synced = function() {
            current_temp = temperature_store:temperatures().head()

            ent:last_temp != null && ent:last_temp{"temperature"} != null && ent:last_temp{"timestamp"} != null &&
            current_temp!= null && current_temp{"temperature"} != null && current_temp{"timestamp"} &&
            ent:last_temp{"temperature"} == current_temp{"temperature"} &&
            ent:last_temp{"timestamp"} == current_temp{"timestamp"}
        }

        extract_message_number = function(message_id) {
            message_id.split(re#:#).reverse().head().as("Number")
        }

        scheduled_heartbeats = function() {
            schedule:list().filter(function(e) {
                e{["event", "domain"]} == "gossip" && 
                e{["event", "name"]} == "heartbeat"
            })
        }

        peer_in_most_need = function() {
            peers = subs:established().map(function(peer) {
                gossip_id = ent:sub_to_gossip{peer{"Id"}}
                self_summary = ent:peer_summaries{ent:gossip_id}
                peer_summary = ent:peer_summaries{gossip_id} || {}

                num_missing = self_summary.keys()
                    .filter(function(key) {
                        key != gossip_id
                    })
                    .map(function(key) {
                        {
                            "self_number": self_summary{key},
                            "peer_number": peer_summary{key}
                        }
                    })
                    .reduce(function(acc, info) {
                        self_number = info{"self_number"}
                        peer_number = info{"peer_number"}
                        diff = peer_number == null => 
                            self_number + 1 | 
                            self_number - peer_number
                        diff > 0 => 
                            acc + diff | 
                            acc
                    }, 0)
                
                peer.put(["num_missing"], num_missing)
            })

            chosen_peer = peers.sort(function(peer1, peer2){
                peer1{"num_missing"} < peer2{"num_missing"}  => 1 |
                    peer1{"num_missing"} == peer2{"num_missing"} =>  0 | -1
            }).head()

            chosen_peer != null && chosen_peer{"num_missing"} > 0 => chosen_peer.put() | null
        }

        first_needed_message = function(peer_gossip_id) {
            peer_summary = ent:peer_summaries{peer_gossip_id} || {}
            self_summary = ent:peer_summaries{ent:gossip_id}
    
            missing_messages = self_summary.keys()
                .filter(function(gossip_id) {
                    gossip_id != peer_gossip_id
                })
                .map(function(gossip_id) {
                    {
                        "gossip_id": gossip_id,
                        "self_number": self_summary{gossip_id},
                        "peer_number": peer_summary{gossip_id} == null => -1 | peer_summary{gossip_id}
                    }
                })
                .filter(function(info) {
                    info{"self_number"} >= 0 && info{"self_number"} > info{"peer_number"}
                })
                .map(function(info) {
                    gossip_id = info{"gossip_id"}
                    message_number = info{"peer_number"} + 1
                    message_key =  gossip_id + ":" + message_number.as("String")
                    
                    ent:temperature_logs{[gossip_id, message_key]}
                })
            
            missing_messages.head()
        }

        get_unseen_messages = function(peer_summary) {
            ent:temperature_logs.values()
                // Combine all messages into one array
                .reduce(function(acc, log_section) {
                    acc.append(log_section.values())
                }, [])
                .filter(function(message){
                    gossip_id = message{"SensorID"}
                    message_id = message{"MessageID"}
                    message_number = extract_message_number(message{"MessageID"})
                    highest_peer_number = 
                        peer_summary{gossip_id} == null => 
                            -1 | 
                            peer_summary{gossip_id}

                    unknown_origin = peer_summary{gossip_id} == null
                    unseen_message = message_number > highest_peer_number

                    unknown_origin || unseen_message
                })
        }
    }

    /////////////////////////////////////////////////
    // Gossip Part 1: Check if self has new reading
    /////////////////////////////////////////////////

    rule respond_to_heartbeat {
        select when gossip heartbeat
        pre {
            synced = temperature_synced()
        }
        if synced then
            every {
                send_directive("Starting Gossip Round")
            }
        fired {
            schedule gossip event "heartbeat" at time:add(time:now(), {"seconds": ent:gossip_interval})
            raise gossip event "start_round_requested"
        } else {
            schedule gossip event "heartbeat" at time:add(time:now(), {"seconds": ent:gossip_interval})
            raise gossip event "new_self_reading"
        }
    }

    rule send_new_self_reading {
        select when gossip new_self_reading
        pre {
            new_temp = temperature_store:temperatures().head()
            message = {
                "MessageID": ent:gossip_id + ":" + ent:sequence_number,
                "SensorID": ent:gossip_id,
                "Temperature": new_temp{"temperature"},
                "Timestamp": new_temp{"timestamp"}
            }
        }
        send_directive("New reading detected")
        always {
            raise gossip event "rumor" attributes message
            ent:sequence_number := ent:sequence_number + 1
            ent:last_temp := new_temp
        }
    }

    /////////////////////////////////////////////////
    // Gossip Part 2: Decide Message Type
    /////////////////////////////////////////////////

    rule start_gossip_round {
        select when gossip start_round_requested
        pre {
            message_type = random:integer(1) > 0 => "rumor" | "seen"
        }
        if message_type == "rumor" then
            send_directive("Rumor Round Selected")
        fired {
            raise gossip event "rumor_round_requested"
        } else {
            raise gossip event "seen_round_requested"
        }
    }

    /////////////////////////////////////////////////
    // Gossip Part 3: Select Peer and Send Message
    /////////////////////////////////////////////////

    rule start_rumor_round {
        select when gossip rumor_round_requested
        pre {
            peer = peer_in_most_need()
            gossip_id = peer => ent:sub_to_gossip{peer{"Id"}} | null
            message = peer => first_needed_message(gossip_id) | null
            message_number = peer => extract_message_number(message{"MessageID"}) | null
            message_origin = peer => message{"SensorID"} | null
        }
        if peer then
            every {
                send_directive("Rumor Message Selected for peer " + gossip_id, message)
                event:send({
                    "eci": peer{"Tx"},
                    "domain": "gossip", "type": "rumor",
                    "attrs": message
                }, peer{"Tx_host"})
            }
        fired {
            ent:peer_summaries{gossip_id} := ent:peer_summaries{gossip_id}.put([message_origin], message_number)
        }
    }

    rule start_seen_round {
        select when gossip seen_round_requested
        pre {
            num_peers = subs:established().length() || 1
            peer_index = random:integer(num_peers - 1)
            chosen_peer = subs:established().slice(peer_index, peer_index).head() 
        }
        if chosen_peer then 
            every {
                send_directive("Seen Round Starting", chosen_peer)
                event:send({
                    "eci": chosen_peer{"Tx"},
                    "domain": "gossip", "type": "seen",
                    "attrs": {
                        "gossip_id": ent:gossip_id,
                        "summary": ent:peer_summary{ent:gossip_id},
                        "eci": chosen_peer{"Rx"},
                        "host": meta:host
                    }
                }, chosen_peer{"Tx_host"})
            }
    }

    /////////////////////////////////
    // Rumors from Peers
    /////////////////////////////////

    rule process_rumor {
        select when gossip rumor
        pre {
            message_id = event:attrs{"MessageID"}
            gossip_id = event:attrs{"SensorID"}
            message_needed = ent:temperature_logs{[gossip_id, message_id]} == null
        }
        if message_needed then
            send_directive("Needed Rumor Messaged Received")
        fired {
            raise gossip event "needed_rumor_received" attributes event:attrs
        }
    }

    rule determine_rumor_origin {
        select when gossip needed_rumor_received
        pre {
            gossip_id = event:attrs{"SensorID"}
            is_new_origin = ent:temperature_logs{gossip_id} == null
        }
        if is_new_origin then
            send_directive("New origin detected: " + gossip_id)
        fired {
            raise gossip event "rumor_from_new_origin_received" attributes event:attrs
        } else {
            raise gossip event "rumor_from_known_origin_received" attributes event:attrs
        }
    }

    rule process_rumor_from_known_origin {
        select when gossip rumor_from_known_origin_received
        pre {
            message_id = event:attrs{"MessageID"}
            gossip_id = event:attrs{"SensorID"}

            message_number = extract_message_number(message_id)
            highest_message_number = ent:peer_summaries{[ent:gossip_id, gossip_id]}
            updated_summary_number = 
                message_number == highest_message_number + 1 => 
                    message_number | 
                    highest_message_number
            
            self_summary = ent:peer_summaries{ent:gossip_id}

        }
        send_directive("Rumor Received from known origin with message_id " + message_id)
        fired {
            ent:temperature_logs{[gossip_id, message_id]} := event:attrs
            ent:peer_summaries{ent:gossip_id} := self_summary.put([gossip_id], updated_summary_number)
        }
    }

    rule process_rumor_from_new_origin {
        select when gossip rumor_from_new_origin_received
        pre {
            message_id = event:attrs{"MessageID"}
            gossip_id = event:attrs{"SensorID"}

            message_number = extract_message_number(message_id)
            updated_summary_number = 
                message_number == 0 =>
                    message_number |
                    -1
            self_summary = ent:peer_summaries{ent:gossip_id}

        }
        send_directive("Rumor Received from known origin with message_id " + message_id)
        fired {
            ent:temperature_logs{gossip_id} := {}
            ent:peer_summaries{gossip_id} := {}

            ent:temperature_logs{[gossip_id, message_id]} := event:attrs
            ent:peer_summaries{ent:gossip_id} := self_summary.put([gossip_id], updated_summary_number)
        }
    }

    ///////////////////////////////////////
    // Seen from Peers
    ///////////////////////////////////////

    rule process_seen {
        select when gossip seen
            foreach get_unseen_messages(event:attrs{"summary"}) setting (unseen_message)
                pre {
                    destination = event:attrs{"eci"}
                    host = event:attrs{"host"}
                    gossip_id = event:attrs{"gossip_id"}    
                }
                every {
                    send_directive("Sending Message")
                    event:send({
                        "eci": destination,
                        "domain": "gossip", "type": "rumor",
                        "attrs": unseen_message
                    }, host)
                }
                always {
                    ent:peer_summary{gossip_id} := event:attrs{"summary"} on final 
                }


        /**
            The rule for responding to seen events should check for any 
            rumors the pico knows about that are not in the seen message 
            and send them (as rumors) to the pico that sent the seen event.  
            Note that how this is done affects the amount of time it takes 
            for the network to reach consistency. For example, you could 
            just send one needed piece of information (the stingy algorithm) 
            or all of the needed information. 
        */
    }

    /////////////////////////////////
    // Subscription Management
    /////////////////////////////////

    rule add_peer {
        select when gossip peer_connection_requested
        pre {
            wellKnown_eci = event:attrs{"wellKnown_eci"}
            gossip_id = event:attrs{"gossip_id"}
            their_host = event:attrs{"host"}.klog("Host")
            x = meta:host.klog("Meta")
        }
        if wellKnown_eci && gossip_id then
            every {
                send_directive("Peer to be added")
                event:send({
                    "eci": wellKnown_eci,
                    "domain": "wrangler", "type": "subscription",
                    "attrs": {
                        "wellKnown_Tx": subs:wellKnown_Rx(){"id"},
                        "Tx_role": "node",
                        "Tx_host": "http://1dfc38153d9d.ngrok.io",
                        "rx_gossip_id": ent:gossip_id, 
                        "Rx_role": "node",
                        "Rx_host": their_host,
                        "tx_gossip_id": gossip_id,
                        "name": ent:gossip_id + ":" + gossip_id,
                        "channel_type": "subscription",
                    }
                }, their_host)
            }
    }

    rule auto_accept {
        select when wrangler inbound_pending_subscription_added
        pre {
          my_role = event:attrs{"Rx_role"}
          their_role = event:attrs{"Tx_role"}
          their_gossip_id = event:attrs{"tx_gossip_id"}
          sub_id = event:attrs{"Id"}
        }
        if my_role=="node" && their_role=="node" && their_gossip_id then
            send_directive("Subscription Request for "+ their_gossip_id + " approved")
        fired {
            raise wrangler event "pending_subscription_approval"
                attributes event:attrs
            ent:sub_to_gossip{sub_id} := their_gossip_id
            ent:temperature_logs{their_gossip_id} := {}
            ent:peer_summaries{ent:gossip_id} := ent:peer_summaries{ent:gossip_id}.put([their_gossip_id], -1)
            ent:peer_summaries{their_gossip_id} := {}
        } else {
            raise wrangler event "inbound_rejection"
                attributes event:attrs
        }
    }

    rule record_successful_subscription {
        select when wrangler outbound_pending_subscription_approved
        pre {
           their_gossip_id = event:attrs{"rx_gossip_id"}
           sub_id = event:attrs{"Id"}
        }
        send_directive("Subscription Request for "+ their_gossip_id + " approved")
        always {
            ent:sub_to_gossip{sub_id} := their_gossip_id
            ent:temperature_logs{their_gossip_id} := {}
            ent:peer_summaries{ent:gossip_id} := ent:peer_summaries{ent:gossip_id}.put([their_gossip_id], -1)
            ent:peer_summaries{their_gossip_id} := {}
        }
    }

    ///////////////////////////
    // State Control 
    ///////////////////////////
    rule init {
        select when wrangler ruleset_installed
          where event:attrs{"rid"} == meta:rid || event:attrs{"rids"} >< meta:rid
        send_directive("Initializing Gossip")
        always {
            ent:gossip_id := random:uuid()
            raise gossip event "reset_requested"
        }
    }

    rule change_time_interval {
        select when gossip interval_modified
        pre {
            new_interval = event:attrs{"interval"} || 0
        }
        if new_interval > 0 then send_directive("Interval Changed")
        fired {
            ent:gossip_interval := new_interval
        }
    }

    rule reset_state {
        select when gossip reset_requested
        send_directive("Resetting state")
        always {
            raise gossip event "stop_requested"
            ent:sequence_number := 0
            ent:temperature_logs := {}
            ent:temperature_logs{ent:gossip_id} := {}
            ent:peer_summaries := {}
            ent:peer_summaries{ent:gossip_id} := {}
            ent:peer_summaries{[ent:gossip_id, ent:gossip_id]} := -1
            ent:sub_to_gossip := {}
            ent:gossip_interval := default_interval
            ent:last_temp := null
            raise gossip event "restart_requested"   
        }
    }

    rule remove_subscriptions {
        select when gossip reset_requested
            foreach subs:established() setting (sub)
                send_directive("Deleting Subscription", sub)
                always {
                    raise wrangler event "subscription_cancellation" attributes {
                        "Id": sub{"Id"}
                    }
                }
    }

    rule stop_gossip_heartbeat {
        select when gossip stop_requested
            foreach scheduled_heartbeats() setting (e)
            schedule:remove(e{"id"})
    }

    rule restart_gossip_heartbeat {
        select when gossip restart_requested
        send_directive("Heartbeat Restarted for " + ent:gossip_id)
        always {
            schedule gossip event "heartbeat" at time:add(time:now(), {"seconds": ent:gossip_interval})
        }
    }
}