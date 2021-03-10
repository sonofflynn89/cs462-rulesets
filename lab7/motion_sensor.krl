ruleset motion_sensor {
    meta {
        use module io.picolabs.subscription alias subs
    }
    rule create_subscription {
        select when sensor subscribe
        pre {
            collection_eci = event:attrs{"collection_eci"}
        }
        event:send(
            { 
                "eci": collection_eci, 
                "eid": "subscription_request",
                "domain": "sensor", "type": "subscription_requested",
                "attrs" : {
                    "sensor_name": "Random_Motion",
                    "wellKnown_eci": subs:wellKnown_Rx(){"id"},
                    "requester_role": "motion_sensor"
                }
            }
        )
    }
}