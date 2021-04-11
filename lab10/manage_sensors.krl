ruleset manage_sensors {
    meta {
        use module io.picolabs.wrangler alias wrangler
        shares sensors, all_temperatures, sensor_profiles
        provides sensors, all_temperatures, sensor_profiles
    }

    global {
        base_url = meta:rulesetConfig{"base_url"} ||
        "file://C:/Users/Gina Pomar/cs462/cs462-rulesets"

        sensors = function() {
            ent:sensors || {}
        }
        all_temperatures = function() {
            ent:sensors.map(function(sensor_vals, sensor_name) {
                ctx:query(sensor_vals{"eci"}, "temperature_store", "temperatures")
            })
        }
        default_threshold = 74
        sms_number = "+19519708437"

        //////////////////////////
        // Testing Function Only
        //////////////////////////
        sensor_profiles = function() {
            ent:sensors.map(function(sensor_vals, sensor_name) {
                ctx:query(sensor_vals{"eci"}, "sensor_profile", "profile")
            })
        }
    }

    /////////////////////////////
    // Cleanup Code
    /////////////////////////////

    rule clear_all_state {
        select when gossip complete_reset_requested
            foreach ent:sensors.keys() setting (child_name)
                event:send({ 
                    "eci": ent:sensors{[child_name, "eci"]}, 
                    "domain": "gossip", "type": "reset_requested",
                    "attrs": {}
                })
    }

    rule stop_all_heartbeats {
        select when gossip all_stop_requested
            foreach ent:sensors.keys() setting (child_name)
                event:send({ 
                    "eci": ent:sensors{[child_name, "eci"]}, 
                    "domain": "gossip", "type": "stop_requested",
                    "attrs": {}
                })
    }

    rule restart_all_heartbeats {
        select when gossip all_restart_requested
            foreach ent:sensors.keys() setting (child_name)
                event:send({ 
                    "eci": ent:sensors{[child_name, "eci"]}, 
                    "domain": "gossip", "type": "restart_requested",
                    "attrs": {}
                })
    }

    rule change_all_intervals {
        select when gossip all_interval_change_requested
            foreach ent:sensors.keys() setting (child_name)
                pre {
                    new_interval = event:attrs{"new_interval"}.as("Number")
                }
                event:send({ 
                    "eci": ent:sensors{[child_name, "eci"]}, 
                    "domain": "gossip", "type": "interval_modified",
                    "attrs": {
                        "interval": new_interval
                    }
                })
    }

    /////////////////////////////
    // Original Code
    ////////////////////////////

    rule initialize_sensors {
        select when sensor needs_initialization
        always {
          ent:sensors := {}
        }
    }

    rule add_sensor {
        select when sensor new_sensor
        pre {
            sensor_name = event:attrs{"sensor_name"}
            exists = (ent:sensors || {}) >< sensor_name
        }
        if exists then
            send_directive("Sensor already exists")
        notfired {
            raise wrangler event "new_child_request"
                attributes { 
                    "name": sensor_name, 
                    "backgroundColor": "#ff69b4",
                    "sensor_name": sensor_name
                }
        }
    }

    rule store_new_sensor {
        select when wrangler new_child_created
        pre {
            sensor = {"eci": event:attrs{"eci"}}
            sensor_name = event:attrs{"sensor_name"}
        }
        if sensor_name.klog("found sensor_name") then
            every {
                event:send(
                    { 
                        "eci": sensor{"eci"}, 
                        "eid": "install-ruleset",
                        "domain": "wrangler", "type": "install_ruleset_request",
                        "attrs": {
                            "absoluteURL":  base_url + "/lab10/sensor_profile.krl",
                            "rid": "sensor_profile",
                            "config": {},
                            "sensor_name": sensor_name
                        }
                    }
                )
                event:send(
                    { 
                        "eci": sensor{"eci"}, 
                        "eid": "install-ruleset",
                        "domain": "wrangler", "type": "install_ruleset_request",
                        "attrs": {
                            "absoluteURL":  base_url + "/lab10/temperature_store.krl",
                            "rid": "temperature_store",
                            "config": {},
                        }
                    }
                )
                event:send(
                    { 
                        "eci": sensor{"eci"}, 
                        "eid": "install-ruleset",
                        "domain": "wrangler", "type": "install_ruleset_request",
                        "attrs": {
                            "absoluteURL":  base_url + "/lab10/wovyn_base.krl",
                            "rid": "wovyn_base",
                            "config": {},
                        }
                    }
                )
                event:send(
                    { 
                        "eci": sensor{"eci"}, 
                        "eid": "install-ruleset",
                        "domain": "wrangler", "type": "install_ruleset_request",
                        "attrs": {
                            "absoluteURL": "https://raw.githubusercontent.com/windley/temperature-network/main/io.picolabs.wovyn.emitter.krl",
                            "rid": "io.picolabs.wovyn.emitter",
                            "config": {},
                        }
                    }
                )
                event:send(
                    { 
                        "eci": sensor{"eci"}, 
                        "eid": "install-ruleset",
                        "domain": "wrangler", "type": "install_ruleset_request",
                        "attrs": {
                            "absoluteURL":  base_url + "/lab10/gossip.krl",
                            "rid": "gossip",
                            "config": {},
                        }
                    }
                )
            }

        fired {
            ent:sensors{sensor_name} := sensor
        }
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
                            "threshold": default_threshold,
                            "sms_number": sms_number
                        }
                    }
                )
            }
    }

    rule delete_sensor {
        select when sensor unneeded_sensor
        pre {
          sensor_name = event:attrs{"sensor_name"}
          exists = ent:sensors >< sensor_name
          eci_to_delete = ent:sensors{[sensor_name,"eci"]}
        }
        if exists && eci_to_delete then
          send_directive("deleting_sensor", {"sensor_name":sensor_name})
        fired {
          raise wrangler event "child_deletion_request"
            attributes {"eci": eci_to_delete};
          clear ent:sensors{sensor_name}
        }
    }

    ///////////////////////////////////////////////////////
    // The Following Rules are only for the test harness
    ///////////////////////////////////////////////////////

    rule delete_all_sensors {
        select when test sensors_unneeded
            foreach ent:sensors.keys() setting (sensor_name)
            always {
                raise sensor event "unneeded_sensor"
                    attributes {
                        "sensor_name": sensor_name
                    }
            }
    }

    rule send_reading_to_sensor {
        select when test new_reading
        pre {
            temperature = event:attrs{"temperature"}
            sensor_name = event:attrs{"sensor_name"}
            sensor = ent:sensors{sensor_name}
            fake_reading =  {
                "data": {
                    "temperature": [
                        {
                            "temperatureF": temperature,
                        }
                    ]
                }
            }
        }
        event:send(
            { 
                "eci": sensor{"eci"}, 
                "eid": "testing-temperature",
                "domain": "wovyn", "type": "heartbeat",
                "attrs": {
                    "genericThing": fake_reading
                }
            }
        )
    }
}