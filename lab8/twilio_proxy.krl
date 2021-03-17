ruleset twilio_proxy {
    meta {
        provides sendSMS, messages
        configure using 
            sid = "" 
            authToken = ""
            twilioNumber = ""
    }
    global {
        messages = function(pageSize, page, pageToken, sender, recipient) {
            qs1 = "?"
            qs2 = pageSize => qs1 + <<PageSize=#{pageSize}&>> | qs1
            qs3 = page => qs2 + <<Page=#{page}&>> | qs2
            qs4 = pageToken => qs3 + <<PageToken=#{pageToken}&>> | qs3
            qs5 = sender => qs4 + <<From=#{sender}&>> | qs4
            qs6 = recipient => qs5 + <<To=#{recipient}>> | qs5

            http:get(
                <<https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json#{qs6}>>, 
                auth = {
                    "username": sid,
                    "password": authToken
                },
                headers = {"Accept": "application/json"},
                parseJSON = true
            )
        }

        sendSMS = defaction(recipient, message) {
            http:post(
                <<https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json>>, 
                form = {
                    "Body": message,
                    "To": recipient,
                    "From": twilioNumber
                },
                auth = {
                    "username": sid,
                    "password": authToken
                }
            ) setting(response)
            return response
        }
    }
}