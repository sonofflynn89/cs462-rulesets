ruleset wovyn_base {
    meta {
        use module sensor_profile
        use module io.picolabs.subscription alias subs
    }

    rule process_heartbeat {
        select when wovyn heartbeat
        pre {
            msg = "I got a temperature read"
            generic_thing = event:attrs{"genericThing"}
        }
        if (generic_thing) 
            then send_directive(msg)
        fired {
            raise wovyn event "new_temperature_reading"
                attributes {
                    "temperature" : event:attrs{"genericThing"}{"data"}{"temperature"}[0]{"temperatureF"}.as("Number"),
                    "timestamp" : time:now()
                }
        }
    }

    rule find_high_temps {
        select when wovyn new_temperature_reading
        pre {
            threshold = sensor_profile:threshold()
        }
        if (event:attrs{"temperature"} > threshold)
            then send_directive("High Temperature Found")
        fired {
            raise wovyn event "threshold_violation"
                attributes event:attrs
        }
    }

    // rule threshold_notification {
    rule notify_collections_of_violation {
        select when wovyn threshold_violation
        foreach subs:established("Tx_role", "collection") setting (sub)
        event:send({
            "eci":sub{"Tx"},
            "eid":"notify_threshold_violation",             
            "domain":"sensor",
            "type":"threshold_violation",
            "attrs": event:attrs
        })
        
        // pre {
        //     actual = event:attrs{"temperature"}
        //     threshold = sensor_profile:threshold()
        //     message = <<Temperature threshold violation
        //     Threshold: #{threshold}
        //     Actual: #{actual}>>
        //     recipient = sensor_profile:sms_number()
        // }
        // // twilio_proxy:sendSMS(recipient, message)
        // send_directive("Send SMS", event:attrs)
    }
}