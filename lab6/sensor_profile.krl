ruleset sensor_profile {
    meta {
        provides threshold, sms_number, profile
        shares threshold, sms_number, profile
        use module io.picolabs.wrangler alias wrangler
    }

    global {
        threshold = function() {
            ent:threshold
        }

        sms_number = function() {
            ent:sms_number
        }

        profile = function() {
            {
                "name": ent:name,
                "location": ent:location,
                "threshold": ent:threshold,
                "sms_number": ent:sms_number
            }
        }

    }

    rule update_profile {
        select when sensor profile_updated
        pre {
            new_name = event:attrs{"name"} || ent:name
            new_location = event:attrs{"location"} || ent:location
            new_threshold = event:attrs{"threshold"} || ent:threshold
            new_sms_number = event:attrs{"sms_number"} || ent:sms_number
        }

        send_directive("Update Profile", event:attrs)

        fired {
            ent:name := new_name
            ent:location := new_location
            ent:threshold := new_threshold
            ent:sms_number := new_sms_number
        }
    }

    rule notify_installation {
        select when wrangler ruleset_installed
          where event:attrs{"rid"} == meta:rid
        pre {
            
            parent_eci = wrangler:parent_eci()
            self_eci = wrangler:myself(){"eci"}
            sensor_name = event:attrs{"sensor_name"}
        }
        if parent_eci && self_eci && sensor_name then
            every {
                send_directive("sensor_profile installed in " + self_eci)
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
            }
            
        always {
            ent:name := "Default"
            ent:location := "Default"
            ent:threshold := 212
            ent:sms_number := ""
        }
    }
}