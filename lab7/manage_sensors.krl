ruleset manage_sensors {
    meta {
        use module io.picolabs.wrangler alias wrangler
        use module io.picolabs.subscription alias subs
        shares sensors, all_temperatures, sensor_profiles
        provides sensors, all_temperatures, sensor_profiles
    }

    global {
        sensors = function() {
            ent:sensors || {}
        }
        all_temperatures = function() {
            subs:established("Tx_role", "temp_sensor").map(function(sub_info) {
                wrangler:picoQuery(
                    sub_info{"Tx"}, // ECI
                    "temperature_store", // Ruleset
                    "temperatures", // Function
                    null, // Params
                    sub_info{"Tx_host"} // Host of Pico
                )
            })
        }
        //////////////////////////
        // Testing Function Only
        //////////////////////////
        sensor_profiles = function() {
            ent:sensors.map(function(sensor_vals, sensor_name) {
                ctx:query(sensor_vals{"eci"}, "sensor_profile", "profile")
            })
        }
    }

    ////////////////////////////
    // Sensor Management
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
                            "absoluteURL": "file://C:/Users/Gina Pomar/cs462/cs462-rulesets/lab7/sensor_profile.krl",
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
                            "absoluteURL": "file://C:/Users/Gina Pomar/cs462/cs462-rulesets/lab7/temperature_store.krl",
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
                            "absoluteURL": "file://C:/Users/Gina Pomar/cs462/cs462-rulesets/lab7/wovyn_base.krl",
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
            }

        fired {
            ent:sensors{sensor_name} := sensor
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

    /////////////////////
    // Subscriptions
    /////////////////////

    rule subscribe_to_sensor {
        select when sensor subscription_requested
        pre {
            wellKnown_eci = event:attrs{"wellKnown_eci"}
            sensor_name = event:attrs{"sensor_name"}
            their_role = event:attrs{"requester_role"}
            their_host = event:attrs{"host"} || null
        }
        if  wellKnown_eci && sensor_name && their_role then
            every {
                send_directive("Start subscription process to sensor " + sensor_name)
                event:send({
                    "eci": wellKnown_eci,
                    "domain": "wrangler", "type": "subscription",
                    "attrs": {
                        "wellKnown_Tx": subs:wellKnown_Rx(){"id"},
                        "Tx_role": "collection",
                        "Tx_host": "http://366a94bb8c21.ngrok.io",
                        "Rx_role": their_role,
                        "Rx_host": their_host,
                        "name": "collection-" + sensor_name,
                        "channel_type": "subscription",     
                    }
                }, their_host)
            }
    }

    rule auto_accept {
        select when wrangler inbound_pending_subscription_added
        pre {
          my_role = event:attrs{"Rx_role"}
          their_role = event:attrs{"Tx_role"}
        }
        if my_role=="collection" && (their_role=="temp_sensor" || their_role=="co2_sensor") then
            send_directive("Subscription Request for " + my_role + "-" + their_role + " approved")
        fired {
          raise wrangler event "pending_subscription_approval"
            attributes event:attrs
        } else {
          raise wrangler event "inbound_rejection"
            attributes event:attrs
        }
    }


    ///////////////////////////////////////////////////////
    // The Following Rules are only for the test harness
    ///////////////////////////////////////////////////////

    rule delete_all_sensors {
        select when test sensors_unneeded
            foreach ent:sensors.keys() setting (sensor_name)
            always {
                raise test event "subs_unneeded"
                raise sensor event "unneeded_sensor"
                    attributes {
                        "sensor_name": sensor_name
                    }
            }
    }

    rule delete_all_subscriptions {
        select when test subs_unneeded
            foreach subs:established() setting (sub)
                send_directive("Deleting Subscription", sub)
            always {
                raise wrangler event "subscription_cancellation" attributes {
                  "Id": sub{"Id"}
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