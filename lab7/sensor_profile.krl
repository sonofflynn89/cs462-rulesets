ruleset sensor_profile {
    meta {
        provides threshold, profile
        shares threshold, profile
        use module io.picolabs.wrangler alias wrangler
        use module io.picolabs.subscription alias subs
    }

    global {
        threshold = function() {
            ent:threshold
        }

        profile = function() {
            {
                "name": ent:name,
                "location": ent:location,
                "threshold": ent:threshold,
            }
        }

    }

    rule update_profile {
        select when sensor profile_updated
        pre {
            new_name = event:attrs{"name"} || ent:name
            new_location = event:attrs{"location"} || ent:location
            new_threshold = event:attrs{"threshold"} || ent:threshold
        }

        send_directive("Update Profile", event:attrs)

        fired {
            ent:name := new_name
            ent:location := new_location
            ent:threshold := new_threshold
        }
    }

    rule notify_installation {
        select when wrangler ruleset_installed
          where event:attrs{"rid"} == meta:rid
        pre {
            parent_eci = wrangler:parent_eci()
            self_eci = wrangler:myself(){"eci"}
            sensor_name = event:attrs{"sensor_name"}
            wellKnown_eci = subs:wellKnown_Rx(){"id"}
        }
        if sensor_name then
            every {
                send_directive("sensor_profile installed in " + self_eci)
                // Notify of Installation
                event:send(
                    { 
                        "eci": parent_eci, 
                        "eid": "sensor_profile_installed",
                        "domain": "sensor", "type": "sensor_profile_installed",
                        "attrs": {
                            "eci": self_eci,                
                            "sensor_name": sensor_name
                        }
                    }
                )
                // Send Subscription Information
                event:send(
                    {
                        "eci": parent_eci, 
                        "eid": "subscription_request",
                        "domain": "sensor", "type": "subscription_requested",
                        "attrs" : {
                            "sensor_name": sensor_name,
                            "wellKnown_eci": wellKnown_eci,
                            "requester_role": "temp_sensor"
                        }
                    }
                )
            }
        //////////////////////////
        // Initialize Profile
        //////////////////////////
        always {
            ent:name := "Default"
            ent:location := "Default"
            ent:threshold := 212
        }
    }
}