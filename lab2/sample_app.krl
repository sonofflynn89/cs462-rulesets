ruleset sample_app {
    meta {
      use module twilio_proxy
        with
            sid = meta:rulesetConfig{"sid"} 
            authToken = meta:rulesetConfig{"authToken"}
            twilioNumber = meta:rulesetConfig{"twilioNumber"}
    }

    rule test_sms {
        select when test sms
        pre {
            recipient = event:attr("recipient").klog("our passed in recipient: ")
            message = event:attr("message").klog("our passed in message: ")
        }
        twilio_proxy:sendSMS(recipient, message)
    }

    rule test_messages {
        select when test messages
        pre {
            pageSize = event:attr("pageSize").klog("our passed in pageSize: ")
            page = event:attr("page").klog("our passed in page: ")
            pageToken = event:attr("pageToken").klog("our passed in pageToken: ")
            sender = event:attr("sender").klog("our passed in sender: ")
            recipient = event:attr("recipient").klog("our passed in recipient: ")
            
            json_from_url = twilio_proxy:messages(pageSize, page, pageToken, sender, recipient){"content"};
        }
        send_directive("results", json_from_url)
    }


}