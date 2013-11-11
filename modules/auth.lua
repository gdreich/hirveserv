local ev = require( "ev" )
local loop = ev.Loop.default

local json = require( "cjson.safe" )

local bcrypt = require( "bcrypt" )
local words = require( "include.words" )

lfs.mkdir( "data/users" )

local users = { }
local tempAuths = { }

-- temp auths garbage collection
ev.Timer.new( function()
	for name, time in pairs( tempAuths ) do
		if time > os.time() then
			tempAuths[ name ] = nil
		end
	end
end, 1, chat.config.tempAuthDuration * 2 )

local function saveUser( user )
	if not user then
		return
	end

	local file = assert( io.open( "data/users/%s.json" % user.name, "w" ) )

	local toSave = {
		password = user.password,
		pending = user.pending,
		settings = user.settings,
		privs = user.privs,
		ips = user.ips,
	}

	file:write( json.encode( toSave ) )
	file:close()
end

local function checkUser( user, decoded, err )
	if not decoded then
		log.warn( "Couldn't decode %s: %s", user, err )
		return nil
	end

	if not decoded.password then
		log.warn( "%s doesn't have a password, skipping", user )
		return nil
	end

	decoded.name = user
	decoded.settings = decoded.settings or { }
	decoded.privs = decoded.privs or { }
	decoded.ips = decoded.ips or { }
	decoded.clients = { }

	decoded.save = function( self )
		saveUser( self )
	end

	decoded.msg = function( self, msg, ... )
		for _, client in ipairs( self.clients ) do
			client:msg( msg, ... )
		end
	end

	return decoded
end

for file in lfs.dir( "data/users" ) do
	local user = file:match( "^(%l+)%.json$" )

	if user then
		local contents, err = io.contents( "data/users/" .. file )

		if contents then
			users[ user ] = checkUser( user, json.decode( contents ) )
		else
			log.warn( "Couldn't read user json: %s", err )
		end
	end
end

local function iptoint( ip )
	local a, b, c, d = ip:match( "^(%d+)%.(%d+)%.(%d+)%.(%d+)$" )
	return d + 256 * ( c + 256 * ( b + 256 * a ) )
end

local function ipauth( client )
	local addr = client.socket:getpeername()
	local n = iptoint( addr )

	for _, ip in ipairs( client.user.ips ) do
		local m = iptoint( ip.ip )
		local div = 2 ^ ( 32 - ip.prefix )

		if math.floor( m / div ) == math.floor( n / div ) then
			return true
		end
	end

	return false
end

chat.command( "auth", "adduser", function( client, name )
	tempAuths[ name:lower() ] = os.time() + chat.config.tempAuthDuration

	chat.msg( "#ly%s#lw is authing #ly%s#lw temporarily.", client.name, name )
end, "<name>", "Authenticate someone for %d second%s" % {
	chat.config.tempAuthDuration,
	string.plural( chat.config.tempAuthDuration )
} )

chat.command( "adduser", "adduser", function( client, name )
	-- it makes addprivs annoying
	if name:match( "%s" ) then
		client:msg( "Usernames can't contain spaces!" )
		return
	end

	local lower = name:lower()

	if users[ lower ] then
		client:msg( "#ly%s#lw already has an account!", name )
		return
	end

	local password = words.random()

	local salt = bcrypt.salt( chat.config.bcryptRounds )
	local digest = bcrypt.digest( password, salt )

	users[ lower ] = {
		password = digest,
		pending = true,
	}

	checkUser( name, users[ name ] )
	saveUser( users[ name ] )

	client:msg( "Ok! Tell #ly%s#lw their password is #lm%s#lw.", name, password )
	chat.msg( "#ly%s#lw added user #ly%s#lw.", client.name, name )
end, "<account>", "Create a new user account" )

chat.command( "deluser", "accounts", function( client, name )
	local lower = name:lower()

	if not users[ lower ] then
		client:msg( "#ly%s#lw doesn't have an account.", name )
		return
	end

	local ok, err = os.remove( "data/users/%s.json" % lower )

	if not ok then
		error( "Couldn't delete user: %s" % err )
	end

	users[ lower ] = nil

	chat.msg( "#ly%s#lw deleted account #ly%s#lw.", client.name, lower )
end, "<account>", "Remove an account" )

chat.command( "setpw", "user", function( client, password )
	if password == "" then
		client:msg( "No empty passwords." )
		return
	end

	local salt = bcrypt.salt( chat.config.bcryptRounds )
	local digest = bcrypt.digest( password, salt )

	client.user.password = digest
	client.user:save()

	client:msg( "Your password has been updated." )
end, "<password>", "Change your password" )

chat.command( "whois", nil, function( client, name )
	local lower = name:lower()
	local other = users[ lower ]

	if not other then
		other = chat.clientFromName( lower )

		if not other then
			client:msg( "There's nobody called #ly%s#lw.", name )
			return
		end

		if not other.user then
			client:msg( "Whois #ly%s#lw: #lrUNAUTHENTICATED", other.name )
			return
		end

		other = other.user
	end

	local privs = "#lwprivs:#lm"
	for priv in pairs( other.privs ) do
		privs = privs .. " " .. priv
	end

	local clients = "#lwclients:#ly"
	for _, c in ipairs( other.clients ) do
		if c.state == "chatting" then
			clients = clients .. " " .. c.name
		end
	end

	client:msg( "Whois #ly%s#lw: %s %s", lower, privs, clients )
end, "<account>", "Displays account info" )

chat.command( "addprivs", "accounts", {
	[ "^(%S+)%s+(.-)$" ] = function( client, name, privs )
		local other = users[ name:lower() ]

		if not other then
			client:msg( "There's nobody called #ly%s#lw.", name )
			return
		end

		local privList = { }
		local bad = { }

		for priv in privs:gmatch( "(%a+)" ) do
			other.privs[ priv ] = true
			table.insert( privList, priv )
		end

		other:save()

		local nice = "#lm" .. table.concat( privList, "#lw,#lm " )

		client:msg( "Gave #ly%s %s #lwprivs.", other.name, nice )
		other:msg( "You have been granted %s#lw privs.", nice )
	end,
}, "<account> <priv1> [priv2 ...]", "Grant a user privs" )

chat.command( "remprivs", "accounts", {
	[ "^(%S+)%s+(.-)$" ] = function( client, name, privs )
		local other = users[ name:lower() ]

		if not other then
			client:msg( "There's nobody called #ly%s#lw.", name )
			return
		end

		local privList = { }

		for priv in privs:gmatch( "(%a+)" ) do
			other.privs[ priv ] = nil
			table.insert( privList, priv )
		end

		other:save()

		local nice = "#lm" .. table.concat( privList, "#lw,#lm " )

		client:msg( "Revoked #ly%s#lw's %s #lwprivs.", other.name, nice )
		other:msg( "Your %s#lw privs have been revoked.", nice )
	end,
}, "<account> <priv1> [priv2 ...]", "Revoke a user's privs" )

chat.handler( "register", { "pm" }, function( client )
	client:msg( "Hey, #ly%s#lw, you should have been given an #lmextremely secret#lw password. #ly/chat#lw me that!", client.name )

	while true do
		local command, args = coroutine.yield()

		if command == "pm" then
			if bcrypt.verify( args, client.user.password ) then
				break
			end

			client:kill( "Nope." )

			return
		end
	end

	while true do
		client:msg( "What do you want your #lmactual#lw password to be?" )

		local command, args = coroutine.yield()

		if command == "pm" then
			if args == "" then
				client:msg( "No empty passwords." )
			else
				local salt = bcrypt.salt( chat.config.bcryptRounds )
				local digest = bcrypt.digest( args, salt )

				client.user.password = digest
				client.user.pending = nil
				client.user:save()

				break
			end
		end
	end

	client:replaceHandler( "chat" )
end )

chat.handler( "auth", { "pm" }, function( client )
	local lower = client.name:lower()

	client.user = users[ client.name:lower() ]

	if not client.user then
		if tempAuths[ lower ] and os.time() < tempAuths[ lower ] then
			tempAuths[ lower ] = nil
			client:replaceHandler( "chat" )
		else
			client:kill( "You don't have an account." )
		end

		return
	end

	table.insert( client.user.clients, client )

	if client.user.pending then
		client:replaceHandler( "register" )

		return
	end

	if ipauth( client ) then
		client:replaceHandler( "chat" )

		return
	end

	client:msg( "Hey, #ly%s#lw! #lm/chat#lw me your password.", client.name )

	while true do
		local command, args = coroutine.yield()

		if command == "pm" then
			if bcrypt.verify( args, client.user.password ) then
				client:replaceHandler( "chat" )
			else
				client:kill( "Nope." )
			end

			break
		end
	end
end )

local makeFirstAccount = true
for k in pairs( users ) do
	makeFirstAccount = false
end

if makeFirstAccount then
	io.stdout:write( "Let's make an account! What do you want the username to be? " )
	io.stdout:flush()

	local name
	while true do
		name = io.stdin:read( "*l" ):lower()

		if not name:match( "^%S+$" ) then
			print( "Name can't contain any whitespace!" )
		else
			break
		end
	end

	local password = words.random()

	local salt = bcrypt.salt( chat.config.bcryptRounds )
	local digest = bcrypt.digest( password, salt )

	users[ name ] = {
		password = digest,
		pending = true,
		privs = { all = true },
	}

	checkUser( name, users[ name ] )
	saveUser( users[ name ] )

	print( "Ok! %s's password is %s." % { name, password } )
end
