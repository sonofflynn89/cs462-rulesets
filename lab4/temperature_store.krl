ruleset temperature_store {

    meta {
        provides temperatures, threshold_violations, inrange_temperatures
        shares temperatures, threshold_violations, inrange_temperatures
    }

    global {
        temperatures = function() {
            ent:temperatures
        }

        threshold_violations = function() {
            ent:threshold_violations
        }

        inrange_temperatures = function() {
            (ent:temperatures || []).filter(function(t) {
               (ent:threshold_violations || []).none(function(v) {
                (t{"temperature"} == v{"temperature"}) && (t{"timestamp"} == v{"timestamp"})
               })
            })
        }
    }
   
    rule collect_temperatures {
        select when wovyn new_temperature_reading
        send_directive("Temperature Collected", event:attrs)
        always {
            ent:temperatures := (ent:temperatures || []).append(event:attrs)
        }
    }

    rule collect_threshold_violations {
        select when wovyn threshold_violation
        send_directive("Threshold Violation Collected", event:attrs)
        always {
            ent:threshold_violations := (ent:threshold_violations || []).append(event:attrs)
        }
    }

    rule clear_temperatures {
        select when sensor reading_reset
        always {
            ent:temperatures := []
            ent:threshold_violations := []
        }
    }
}