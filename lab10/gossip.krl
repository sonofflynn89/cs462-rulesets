ruleset gossip {
    meta {
        use module io.picolabs.subscription alias subs
        use module temperature_store
        use module sensor_profile
        shares temp_health_check, threshold_health_check, peer_in_most_need, first_needed_message, get_unseen_messages, scheduled_heartbeats
        provides temp_health_check, threshold_health_check, peer_in_most_need, first_needed_message, get_unseen_messages, scheduled_heartbeats
        
    }

    global {
        default_interval = 10 // 20 seconds
        my_host = meta:rulesetConfig{"my_host"} || meta:host
        //////////////////////
        // Debug Functions
        //////////////////////
        temp_health_check = function() {
            {
                "my_wellKnown": subs:wellKnown_Rx(){"id"},
                "gossip_id": ent:gossip_id,
                "interval": ent:gossip_interval,
                "temp_sequence": ent:temp_sequence_number,
                "sub_to_gossip": ent:sub_to_gossip,
                "temp_summaries": ent:temp_summaries,
                "logs": ent:temp_logs,
            }
        }

        threshold_health_check = function() {
            {
                "my_wellKnown": subs:wellKnown_Rx(){"id"},
                "gossip_id": ent:gossip_id,
                "interval": ent:gossip_interval,
                "threshold_sequence": ent:threshold_sequence_number,
                "is_violating_threshold": ent:is_violating_threshold,
                "sub_to_gossip": ent:sub_to_gossip,
                "threshold_summaries": ent:threshold_summaries,
                "logs": ent:threshold_logs,
            }
        }

        scheduled_heartbeats = function() {
            schedule:list().filter(function(e) {
                e{["event", "domain"]} == "gossip" && 
                e{["event", "name"]} == "heartbeat"
            })
        }

        ///////////////////////
        // General Utils
        ///////////////////////

        extract_message_number = function(message_id) {
            message_id.split(re#:#).reverse().head().as("Number")
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

        get_counter_increment = function(temp) {
            violates_threshold = temp{"temperature"} > sensor_profile:threshold()
            violation_increase = ent:is_violating_threshold => 0 | 1
            non_violation_decrease = ent:is_violating_threshold => -1 | 0
            violates_threshold => violation_increase | non_violation_decrease
        }

        peer_in_most_need = function() {
            peers = subs:established().map(function(peer) {
                gossip_id = ent:sub_to_gossip{peer{"Id"}}
                self_summary = ent:temp_summaries{ent:gossip_id}
                peer_summary = ent:temp_summaries{gossip_id} || {}

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
            peer_summary = ent:temp_summaries{peer_gossip_id} || {}
            self_summary = ent:temp_summaries{ent:gossip_id}
    
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
                    
                    ent:temp_logs{[gossip_id, message_key]}
                })
            
            missing_messages.head()
        }

        get_unseen_messages = function(peer_summary) {
            ent:temp_logs.values()
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
            //////////////////////////
            // Temperature
            //////////////////////////
            new_temp = temperature_store:temperatures().head()        
            temp_message = {
                "MessageID": ent:gossip_id + ":" + ent:temp_sequence_number,
                "SensorID": ent:gossip_id,
                "Temperature": new_temp{"temperature"},
                "Timestamp": new_temp{"timestamp"},
                "type": "temp"
            }

            //////////////////////////
            // Threshold
            //////////////////////////
            increment = get_counter_increment(new_temp)
            is_violating_threshold = 
                increment == 0 =>
                    ent:is_violating_threshold |
                    not ent:is_violating_threshold    
            threshold_message = {
                "MessageID": ent:gossip_id + ":" + ent:temp_sequence_number,
                "SensorID": ent:gossip_id,
                "counter_increment": increment,
                "type": "threshold"
            }
        }
        send_directive("New reading detected")
        always {
            ///////////////////
            // Temperature
            ///////////////////
            raise gossip event "rumor" attributes temp_message
            ent:temp_sequence_number := ent:temp_sequence_number + 1
            ent:last_temp := new_temp

            ///////////////////
            // Threshold
            ///////////////////
            raise gossip event "rumor" attributes threshold_message
            ent:threshold_sequence_number := ent:threshold_sequence_number + 1
            ent:is_violating_threshold := is_violating_threshold
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
            ent:temp_summaries{gossip_id} := ent:temp_summaries{gossip_id}.put([message_origin], message_number)
        }
    }

    rule start_seen_round {
        select when gossip seen_round_requested
        pre {
            num_peers = subs:established().length()
            peer_index = ent:peer_last_seen + 1 < num_peers =>
                ent:peer_last_seen + 1 | 
                0
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
                        "summary": ent:temp_summaries{ent:gossip_id},
                        "eci": chosen_peer{"Rx"},
                        "host": meta:host
                    }
                }, chosen_peer{"Tx_host"})
            }
            fired {
                ent:peer_last_seen := peer_index
            }
    }

    /////////////////////////////////
    // Temp Rumors from Peers
    /////////////////////////////////

    rule process_rumor {
        select when gossip rumor
        pre {
            message_number = extract_message_number(event:attrs{"MessageID"})
            gossip_id = event:attrs{"SensorID"}
            message_needed = 
                event:attrs{"type"} == "temp" =>
                ent:temp_summary{gossip_id} == null || ent:temp_summary{gossip_id} + 1 == message_number |
                ent:threshold_summary{gossip_id} == null || ent:threshold_summary{gossip_id} + 1 == message_number
        }
        if message_needed && ent:processing_status == "on" then
            send_directive("Needed Rumor Messaged Received")
        fired {
            raise gossip event "needed_rumor_received" attributes event:attrs
        }
    }

    rule determine_temp_rumor_origin {
        select when gossip needed_rumor_received where event:attrs{"type"} == "temp"
        pre {
            gossip_id = event:attrs{"SensorID"}
            is_new_origin = ent:temp_logs{gossip_id} == null
        }
        if is_new_origin then
            send_directive("New origin detected: " + gossip_id)
        fired {
            raise gossip event "rumor_from_new_origin_received" attributes event:attrs
        } else {
            raise gossip event "rumor_from_known_origin_received" attributes event:attrs
        }
    }

    rule process_temp_rumor_from_known_origin {
        select when gossip rumor_from_known_origin_received where event:attrs{"type"} == "temp"
        pre {
            message_id = event:attrs{"MessageID"}
            gossip_id = event:attrs{"SensorID"}

            message_number = extract_message_number(message_id)
            highest_message_number = ent:temp_summaries{[ent:gossip_id, gossip_id]}
            updated_summary_number = 
                message_number == highest_message_number + 1 => 
                    message_number | 
                    highest_message_number
            
            self_summary = ent:temp_summaries{ent:gossip_id}

        }
        send_directive("Temp Rumor Received from known origin with message_id " + message_id)
        fired {
            ent:temp_logs{[gossip_id, message_id]} := event:attrs
            ent:temp_summaries{ent:gossip_id} := self_summary.put([gossip_id], updated_summary_number)
        }
    }

    rule process_temp_rumor_from_new_origin {
        select when gossip rumor_from_new_origin_received where event:attrs{"type"} == "temp"
        pre {
            message_id = event:attrs{"MessageID"}
            gossip_id = event:attrs{"SensorID"}

            message_number = extract_message_number(message_id)
            updated_summary_number = 
                message_number == 0 =>
                    message_number |
                    -1
            self_summary = ent:temp_summaries{ent:gossip_id}

        }
        send_directive("Temp Rumor Received from known origin with message_id " + message_id)
        fired {
            ent:temp_logs{gossip_id} := {}
            ent:temp_summaries{gossip_id} := {}

            ent:temp_logs{[gossip_id, message_id]} := event:attrs
            ent:temp_summaries{ent:gossip_id} := self_summary.put([gossip_id], updated_summary_number)
        }
    }

    ///////////////////////////////////////
    // Threshold Rumors from Peers
    ///////////////////////////////////////

    rule determine_threshold_rumor_origin {
        select when gossip needed_rumor_received where event:attrs{"type"} == "threshold"
        pre {
            gossip_id = event:attrs{"SensorID"}
            is_new_origin = ent:threshold_logs{gossip_id} == null
        }
        if is_new_origin then
            send_directive("New origin detected: " + gossip_id)
        fired {
            raise gossip event "rumor_from_new_origin_received" attributes event:attrs
        } else {
            raise gossip event "rumor_from_known_origin_received" attributes event:attrs
        }
    }

    rule process_threshold_rumor_from_known_origin {
        select when gossip rumor_from_known_origin_received where event:attrs{"type"} == "threshold"
        pre {
            message_id = event:attrs{"MessageID"}
            gossip_id = event:attrs{"SensorID"}

            message_number = extract_message_number(message_id)
            highest_message_number = ent:threshold_summaries{[ent:gossip_id, gossip_id]}
            updated_summary_number = 
                message_number == highest_message_number + 1 => 
                    message_number | 
                    highest_message_number
            
            self_summary = ent:threshold_summaries{ent:gossip_id}

        }
        send_directive("Threshold Rumor Received from known origin with message_id " + message_id)
        fired {
            ent:threshold_logs{[gossip_id, message_id]} := event:attrs
            ent:threshold_summaries{ent:gossip_id} := self_summary.put([gossip_id], updated_summary_number)
        }
    }

    rule process_threshold_rumor_from_new_origin {
        select when gossip rumor_from_new_origin_received where event:attrs{"type"} == "threshold"
        pre {
            message_id = event:attrs{"MessageID"}
            gossip_id = event:attrs{"SensorID"}

            message_number = extract_message_number(message_id)
            updated_summary_number = 
                message_number == 0 =>
                    message_number |
                    -1
            self_summary = ent:threshold_summaries{ent:gossip_id}

        }
        send_directive("Threshold Rumor Received from known origin with message_id " + message_id)
        fired {
            ent:threshold_logs{gossip_id} := {}
            ent:threshold_summaries{gossip_id} := {}

            ent:threshold_logs{[gossip_id, message_id]} := event:attrs
            ent:threshold_summaries{ent:gossip_id} := self_summary.put([gossip_id], updated_summary_number)
        }
    }

    ///////////////////////////////////////
    // Seen from Peers
    ///////////////////////////////////////

    rule filter_seens {
        select when gossip seen 
        pre{
            gossip_id = event:attrs{"gossip_id"}
        }
        if ent:processing_status == "on" then
            send_directive("Seen Received")
        fired {
            ent:temp_summaries{gossip_id} := event:attrs{"summary"}
            raise gossip event "seen_received" attributes event:attrs
        }
    }

    rule process_seen {
        select when gossip seen_received
            foreach get_unseen_messages(event:attrs{"summary"}) setting (unseen_message)
                pre {
                    destination = event:attrs{"eci"}
                    host = event:attrs{"host"}
                    gossip_id = event:attrs{"gossip_id"}
                    message_origin = unseen_message{"SensorID"}
                    message_number = extract_message_number(unseen_message{"MessageID"})   
                }
                every {
                    send_directive("Sending Message")
                    event:send({
                        "eci": destination,
                        "domain": "gossip", "type": "rumor",
                        "attrs": unseen_message
                    }, host)
                }
                fired {
                    ent:temp_summaries{gossip_id} := ent:temp_summaries{gossip_id}.put(message_origin, message_number)
                }
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
                        "Tx_host": my_host,
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

            //////////////////////////////
            // Temperature Initialization
            //////////////////////////////
            ent:temp_logs{their_gossip_id} := {}
            ent:temp_summaries{ent:gossip_id} := ent:temp_summaries{ent:gossip_id}.put([their_gossip_id], -1)
            ent:temp_summaries{their_gossip_id} := {}

            //////////////////////////////
            // Threshold Initialization
            //////////////////////////////
            ent:threshold_logs{their_gossip_id} := {}
            ent:threshold_summaries{ent:gossip_id} := ent:threshold_summaries{ent:gossip_id}.put([their_gossip_id], -1)
            ent:threshold_summaries{their_gossip_id} := {}
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

            //////////////////////////////
            // Temperature Initialization
            //////////////////////////////
            ent:temp_logs{their_gossip_id} := {}
            ent:temp_summaries{ent:gossip_id} := ent:temp_summaries{ent:gossip_id}.put([their_gossip_id], -1)
            ent:temp_summaries{their_gossip_id} := {}

            //////////////////////////////
            // Threshold Initialization
            //////////////////////////////
            ent:threshold_logs{their_gossip_id} := {}
            ent:threshold_summaries{ent:gossip_id} := ent:threshold_summaries{ent:gossip_id}.put([their_gossip_id], -1)
            ent:threshold_summaries{their_gossip_id} := {}
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

    rule change_processing_status {
        select when gossip process
        pre {
            new_status = event:attrs{"status"}
        }
        send_directive("processing status updated to " + new_status)
        fired {
            ent:processing_status := new_status
        }
    }

    rule reset_state {
        select when gossip reset_requested
        send_directive("Resetting state")
        always {
            raise gossip event "stop_requested"

            /////////////////////////////////
            // Temperature Related Variables
            /////////////////////////////////
            ent:temp_sequence_number := 0
            ent:temp_logs := {}
            ent:temp_logs{ent:gossip_id} := {}
            ent:temp_summaries := {}
            ent:temp_summaries{ent:gossip_id} := {}
            ent:temp_summaries{[ent:gossip_id, ent:gossip_id]} := -1

            /////////////////////////////////
            // Threshold Related Variables
            /////////////////////////////////
            ent:threshold_sequence_number := 0
            ent:threshold_logs := {}
            ent:threshold_logs{ent:gossip_id} := {}
            ent:threshold_summaries := {}
            ent:threshold_summaries{ent:gossip_id} := {}
            ent:threshold_summaries{[ent:gossip_id, ent:gossip_id]} := -1
            ent:threshold_counter := 0
            ent:is_violating_threshold := false

            /////////////////////////
            // Other Variables
            /////////////////////////
            ent:sub_to_gossip := {}
            ent:gossip_interval := default_interval
            ent:last_temp := null
            ent:processing_status := "on"
            ent:peer_last_seen := -1

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