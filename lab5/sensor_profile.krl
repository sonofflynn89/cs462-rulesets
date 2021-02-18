ruleset sensor_profile {
    meta {
        provides threshold, sms_number, profile
        shares threshold, sms_number, profile
    }

    global {
        threshold = function() {
            ent:threshold || 70
        }

        sms_number = function() {
            ent:sms_number || "+19519708437"
        }

        profile = function() {
            {
                "name": ent:name || "Wovyn Sensor",
                "location": ent:location || "Talmage Building",
                "threshold": ent:threshold || 70,
                "sms_number": ent:sms_number || "+19519708437"
            }
        }

    }

    rule update_profile {
        select when sensor profile_updated
        pre {
            new_name = event:attrs{"name"} || ent:name || "Wovyn Sensor"
            new_location = event:attrs{"location"} || ent:location || "Talmage Building"
            new_threshold = event:attrs{"threshold"} || ent:threshold || 70
            new_sms_number = event:attrs{"sms_number"} || ent:sms_number || "+19519708437"
        }

        send_directive("Update Profile", event:attrs)

        fired {
            ent:name := new_name
            ent:location := new_location
            ent:threshold := new_threshold
            ent:sms_number := new_sms_number
        }
    }
}