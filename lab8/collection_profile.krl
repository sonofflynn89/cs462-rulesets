ruleset collection_profile {
    meta {
        use module twilio_proxy with
            sid = meta:rulesetConfig{"sid"} 
            authToken = meta:rulesetConfig{"authToken"}
            twilioNumber = meta:rulesetConfig{"twilioNumber"}
    }
    global {
        threshold = 100
        sms_number = "+19519708437"
    }

    rule set_sensor_profile {
        select when sensor sensor_profile_installed
        pre {
            sensor_eci = event:attrs{"eci"}
            sensor_name = event:attrs{"sensor_name"}
        }
        if sensor_eci then
            every {
                send_directive("set sensor profile", event:attrs)
                event:send(
                    { 
                        "eci": sensor_eci, 
                        "eid": "set_sensor_profile",
                        "domain": "sensor", "type": "profile_updated",
                        "attrs": {
                            "name": sensor_name,
                            "threshold": threshold,
                        }
                    }
                )
            }
    }

    rule threshold_notification {
        select when sensor threshold_violation
        pre {
            actual = event:attrs{"temperature"}
            message = <<Temperature threshold violation
            Threshold: #{threshold}
            Actual: #{actual}>>
            recipient = sms_number
        }
        twilio_proxy:sendSMS(recipient, message)
        // send_directive("Send SMS", event:attrs)
    }

}