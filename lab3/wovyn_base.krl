ruleset wovyn_base {
    meta {
        use module twilio_proxy
          with
              sid = meta:rulesetConfig{"sid"} 
              authToken = meta:rulesetConfig{"authToken"}
              twilioNumber = meta:rulesetConfig{"twilioNumber"}
    }

    global {
        recipient = "+19519708437"
        threshold = 50
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
                    "temperature" : event:attrs{"genericThing"}{"data"}{"temperature"}[0]{"temperatureF"},
                    "timestamp" : time:now()
                }
        }
    }

    rule find_high_temps {
        select when wovyn new_temperature_reading
        if (event:attrs{"temperature"} > threshold)
            then noop()
        fired {
            raise wovyn event "threshold_violation"
                attributes event:attrs
        }
    }

    rule threshold_notification {
        select when wovyn threshold_violation
        pre {
            actual = event:attrs{"temperature"}
            message = <<Temperature threshold violation
            Threshold: #{threshold}
            Actual: #{actual}>>
        }
        twilio_proxy:sendSMS(recipient, message)
    }
}