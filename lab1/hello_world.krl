ruleset hello_world {
    meta {
      name "Hello World"
      description <<
  A first ruleset for the Quickstart
  >>
      author "Phil Windley"
      shares hello, monkey, __testing
    }
     
    global {
      hello = function(obj) {
        msg = "Hello " + obj;
        msg
      }

      monkey = function(obj) {
        msg = "Hello " + (obj || "Monkey")
        msg
      }
    }
     
    rule hello_world {
      select when echo hello
      send_directive("say", {"something": "Hello World"})
    }
    
    rule hello_monkey {
      select when echo monkey 
      pre {
        name = (event:attr("name") || "Monkey").klog("our passed in name: ")
      }
      send_directive("say", {"something": name})
    }
  }