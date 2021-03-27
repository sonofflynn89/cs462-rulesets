ruleset gossip {
    meta {
        use module io.picolabs.subscription alias subs
        shares health_check
        provides health_check
    }

    global {
        default_interval = 180 // 3 minutes
        health_check = function() {
            {
                "gossip_id": ent:gossip_id,
                "sequence": ent:sequence_number,
                "logs": ent:temperature_logs,
                "summaries": ent:peer_summaries,
                "interval": ent:gossip_interval,
                "wellKnown_to_gossip_id": ent:wellKnown_to_gossip_id,
                "my_wellKnown": subs:wellKnown_Rx(){"id"}
            }
        }
    }

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
            ent:sequence_number := 0
            ent:temperature_logs := {}
            ent:peer_summaries := {}
            ent:wellKnown_to_gossip_id := {}
            ent:gossip_interval := default_interval
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

    rule start_gossip {
        select when gossip heartbeat
        send_directive("Heartbeat Received")
    }

    rule process_rumor {
        select when gossip rumor
        send_directive("Rumor Received")
    }

    rule process_seen {
        select when gossip seen 
        send_directive("Seen Received")
    }

    ////////////////////////////
    // Subscriptions
    ////////////////////////////

    rule add_peer {
        select when gossip peer_connection_requested
        pre {
            wellKnown_eci = event:attrs{"wellKnown_eci"}
            gossip_id = event:attrs{"gossip_id"}
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
                        "rx_gossip_id": ent:gossip_id, 
                        "Rx_role": "node",
                        "tx_gossip_id": gossip_id,
                        "name": ent:gossip_id + ":" + gossip_id,
                        "channel_type": "subscription",
                    }
                })
            }
    }

    rule auto_accept {
        select when wrangler inbound_pending_subscription_added
        pre {
          test = event:attrs.klog("WAT????")
          my_role = event:attrs{"Rx_role"}
          their_role = event:attrs{"Tx_role"}
          their_wellKnown = event:attrs{"Tx"}
          their_gossip_id = event:attrs{"tx_gossip_id"}
        }
        if my_role=="node" && their_role=="node" && their_gossip_id then
            send_directive("Subscription Request for "+ their_gossip_id + " approved")
        fired {
            ent:wellKnown_to_gossip_id{their_wellKnown} := their_gossip_id
            raise wrangler event "pending_subscription_approval"
                attributes event:attrs
        } else {
            raise wrangler event "inbound_rejection"
                attributes event:attrs
        }
    }

    rule record_subscription {
        select when wrangler outbound_pending_subscription_approved
        pre {
           test = event:attrs.klog("OUTBOUND approved")
           their_gossip_id = event:attrs{"rx_gossip_id"}
           their_wellKnown = event:attrs{"Rx"}
        }
        send_directive("Subscription Request for "+ their_gossip_id + " approved")
        always {
            ent:wellKnown_to_gossip_id{their_wellKnown} := their_gossip_id
        }
    }
}