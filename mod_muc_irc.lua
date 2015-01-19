-- This module hooks makes an irc room accessible over XMPP.
-- It behaves as a muc component

local jid = require "util.jid"
local st = require "util.stanza"
local cqueues = require "cqueues"
local cq = require "net.cqueues".cq
local irc = require "irc"

local irc_server = module:get_option("irc_server")
assert(type(irc_server) == "table")
assert(irc_server.host, "irc host must be provided")

module:depends "muc"

--local connection_pool = {}
local occupant_jid_to_conn = module:shared "nick_to_conn"

module:hook("muc-pre-create", function(event)
	if not event.stanza.to:match "^#" then
		local reply = st.error_reply(event.stanza, "modify", "bad-request", "Invalid room name; must start with '#'")
		event.origin.send(reply)
		return true;
	end
end)

-- Ignore messages to non rooms (i.e. nicks)
for k in pairs {
	["presence/full"] = true;
	["iq/full"] = true;
	["message/full"] = true;
} do
	module:hook(k, function(event)
		if not event.stanza.attr.to:match("^#") then
			module:log("debug", "Ignoring stanza to non-channel: %s", tostring(event.stanza))--:top_tag())
			return true
		end
	end, -1)
end
-- Allow sending private messages to irc users
module:hook("message/full", function(event)
	local to = jid.split(event.stanza.attr.to)
	--if to:match("^#") then return end
	if event.stanza.attr.type == "groupchat" then return end
	local from = event.stanza.attr.from
	local conn = occupant_jid_to_conn[from]
	if not conn then return end
	local body = event.stanza:get_child_text("body")
	if not body then return end
	conn:sendChat(to, body)
	return true
end, 0)

local function to_jid(nick, channel)
	local user_jid = nick .. "@" .. module.host .. "/" .. channel
	local occupant_jid = channel .. "@" .. module.host .. "/" .. nick
	return user_jid, occupant_jid
end

local function get_conn_for_nick(room, occupant_jid)
	local nick = select(3, jid.split(occupant_jid))
	module:log("info", "Connecting to IRC Server for %s", nick)
	local conn = irc.new {
		nick = nick;
		username = "xmppbridge";
		realname = "xmppbridge";
	}
	conn:hook("OnRaw", function(line)
		print("RAW", line)
	end)
	local function build_presence(user, channel)
		local u_jid, o_jid = to_jid(user.nick, channel)
		local p = st.presence({from = u_jid; to = o_jid})
			:tag("x", { xmlns = "http://jabber.org/protocol/muc"; })
				:tag("history", { xmlns = "http://jabber.org/protocol/muc"; maxchars = 0; })
				:up()
			:up()
		return p
	end
	conn:hook("NameList", function(channel, names, msg)
		print("NAMELIST", channel, names, msg)
		for nick, user in pairs(names) do
			local p = build_presence(user, channel)
			print("SENDING", p)
			module:send(p)
		end
	end)
	conn:hook("OnJoin", function(user, channel)
		if user.nick ~= conn.nick then -- Don't send out own
			local p = build_presence(user, channel)
			print("SENDING", p)
			module:send(p)
		end
	end)
	conn:hook("OnPart", function(user, channel, reason)
		if user.nick == conn.nick then
			--TODO?
			if next(o.channels) == nil then
				-- last part. disconnect client.
				conn:disconnect()
			end
		else
			local u_jid, o_jid = to_jid(user.nick, channel)
			local p = st.presence({from = u_jid; to = o_jid; type = "unavailable";})
			if reason then
				p:tag("status"):text(reason):up()
			end
			print("SENDING", p)
			module:send(p)
		end
	end)
	conn:hook("NickChange", function(user, newnick, channel)
		if user.nick == conn.nick then -- Our nick changed
		else
			local p = build_presence(user, channel)
			print("SENDING", p)
			module:send(p)
		end
	end)
	conn:hook("OnChat", function(user, channel, message)
		local attr
		local u_jid, o_jid = to_jid(user.nick, channel)
		if channel:match"^#" then
			attr = { type = "groupchat"; from = u_jid; to = jid.bare(o_jid); }
		else -- channel is our own name
			attr = { type = "chat"; from = u_jid; to = o_jid; }
		end
		local m = st.message(attr, message)
		print("SENDING", m)
		module:send(m)
	end)
	conn:hook("OnTopic", function(channel, topic)
		room:set_subject(nil, topic)
	end)
	conn:hook("OnTopicInfo", function(channel, creator, time)
		local from = channel .. "@" .. module.host .. "/" .. creator
		local prev_from, prev_subject = room:get_subject()
		room:set_subject(from, prev_subject)
	end)
	conn:connect(irc_server)
	cq:wrap(function(conn)
		while cqueues.poll(conn) do
			conn:think()
		end
	end, conn)
	return conn
end

-- When a user joins the xmpp room, have them join the irc room
module:hook("muc-occupant-pre-join", function(event)
	-- Ignore anything from occupants on the irc side
	if select(2, jid.split(event.stanza.attr.from)) == module.host then return end
	local room = event.room
	local room_name = jid.split(room.jid)
	local occupant = event.occupant
	module:log("debug", "%s wants to join %s", event.stanza.attr.from, room_name)
	local conn = occupant_jid_to_conn[occupant.nick]
	if not conn then
		conn = get_conn_for_nick(room, occupant.nick)
		conn:hook("OnDisconnect", function(...)
			print("DISCONNECTED", ...)
			occupant_jid_to_conn[occupant.nick] = nil
		end)
		occupant_jid_to_conn[occupant.nick] = conn
		-- Re-process
		core_post_stanza(event.origin, event.stanza)
		return true
	end
	module:log("debug", "Reusing IRC connection for %s", occupant.jid)
	local joined = conn.channels[room_name]
	if not joined then
		local hook_id; hook_id = conn:hook("OnJoin", function(user, channel)
			if channel == room_name then
				joined = true
				conn:unhook("OnJoin", hook_id)
			end
		end)
		conn:join(room_name)
		while not joined do
			local ok = cqueues.poll(conn)
			print("THINKING", ok)
			conn:think()
		end
	end
end)
module:hook("muc-occcupant-left", function(event)
	local conn = occupant_jid_to_conn[event.occupant.nick]
	if not conn then return end
	local channel = jid.split(event.room.jid)
	module:log("debug", "%s parting channel %s", event.occupant.nick, channel)
	conn:part(channel)
end)
module:hook("muc-broadcast-message", function(event)
	local from = event.stanza.attr.from
	local conn = occupant_jid_to_conn[from]
	if not conn then return end
	local body = event.stanza:get_child_text("body")
	if not body then return end
	local channel = jid.split(from)
	conn:sendChat(channel, body)
end)
