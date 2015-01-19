This is a [Prosody](https://prosody.im) plugin that allows for XMPP MUC clients to access an IRC server.

This module should be loaded on a separate Virtual Host for each IRC server you wish to connect to.

Each different nick will be a separate IRC connection to the server,
so if you use this you may want to get permission from the IRC server owners.


## Dependencies

### Prosody [trunk](https://prosody.im/nightly/trunk/)

Need the new MUC component as well as `net.cqueues`


### [cqueues](http://25thandclement.com/~william/projects/cqueues.html)


### [LuaIRC](https://github.com/JakobOvrum/LuaIRC)

Some modifications are required. (Stay tuned for more info)


## Configuration

mod_muc_irc should be loaded as a Component.

You will need to define a table `irc_server` with fields `host`, `port` and `secure`.

e.g. 

```lua
Component "irc.hashbang.sh" "muc_irc"
	irc_server = {
		host = "irc.hashbang.sh";
		port = 6697;
		secure = true;
	}
```

It could be loaded as an external component if desired.
