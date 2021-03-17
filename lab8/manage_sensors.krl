ruleset manage_sensors {
    meta {
        use module io.picolabs.wrangler alias wrangler
        use module io.picolabs.subscription alias subs
        shares sensors, temp_reports, next_report_id, recent_temp_reports
        provides sensors, temp_reports, next_report_id, recent_temp_reports
    }

    global {
        sensors = function() {
            ent:sensors || {}
        }

        recent_temp_reports = function() {
            ent:temp_reports.keys().filter(
                function(report_id) { ent:next_report_id - report_id <= 5 }
            ).map(
                function(report_id) {
                    {"report_id": report_id}.put(ent:temp_reports{report_id})
                }
            ).reverse()
        }

        // Extra Stuff
        temp_reports = function() {
            ent:temp_reports
        }
        next_report_id = function() {
            ent:next_report_id
        }
    }

    ////////////////////////////
    // Temperature Reports
    ////////////////////////////

    rule init {
        select when wrangler ruleset_installed
          where event:attrs{"rid"} == meta:rid || event:attrs{"rids"} >< meta:rid
        send_directive("Initializing Sensor Manager")
        always {
            ent:next_report_id := 0
            ent:temp_reports := {}
            ent:sensors := {}
        }
    }

    rule send_temp_report_requests {
        select when sensor temp_report_requested
            foreach subs:established("Tx_role", "temp_sensor") setting (sub_info)
                event:send(
                    { 
                        "eci": sub_info{"Tx"}, 
                        "domain": "sensor", "type": "temperature_requested",
                        "attrs": {
                            "requester": sub_info{"Rx"},
                            "report_id": ent:next_report_id
                        }
                    }
                )
            fired {
                ent:temp_reports{ent:next_report_id} := {
                    "temperature_sensors": subs:established("Tx_role", "temp_sensor").length(),
                    "responding": 0,
                    "temperatures": []
                } on final
                ent:next_report_id := ent:next_report_id + 1 on final
            }
    }

    rule collect_temp_report_readings {
        select when sensor temperature_sent
        pre {
            report_id = event:attrs{"report_id"}
            num_responding_sensors = ent:temp_reports{[report_id, "responding"]}
            current_temperatures = ent:temp_reports{[report_id, "temperatures"]}
            new_temperature = event:attrs{"temperature"}
        }
        send_directive("Temperature received for report " + report_id)
        always {
            ent:temp_reports{[report_id, "responding"]} := num_responding_sensors + 1
            ent:temp_reports{[report_id, "temperatures"]} := current_temperatures.append(new_temperature)
            raise sensor event "report_updated" attributes { "report_id": report_id }
        }        
    }

    rule update_report_status {
        select when sensor report_updated
        pre {
            report_id = event:attrs{"report_id"}
            num_responding_sensors = ent:temp_reports{[report_id, "responding"]}
            num_total_sensors = ent:temp_reports{[report_id, "temperature_sensors"]}
        }
        if num_total_sensors == num_responding_sensors then
            send_directive("Report " + report_id + " complete")
        fired {
            raise sensor event "report_complete" attributes event:attrs
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
                            "absoluteURL": "file://C:/Users/Gina Pomar/cs462/cs462-rulesets/lab8/sensor_profile.krl",
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
                            "absoluteURL": "file://C:/Users/Gina Pomar/cs462/cs462-rulesets/lab8/temperature_store.krl",
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
                            "absoluteURL": "file://C:/Users/Gina Pomar/cs462/cs462-rulesets/lab8/wovyn_base.krl",
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