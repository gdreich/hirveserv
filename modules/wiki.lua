local EntriesPerPage = 10

local categories = { }
local categoriesList = { }

local pages = { }

local function checkClash( name )
	assert( not categories[ name ] and not pages[ name ], "name clash: %s" % name )
end

local function loadPage( path )
	local page = assert( io.contents( path ) )
	local title, body = page:match( "^([^\n]+)\n+(.+)$" )

	return {
		title = title,
		body = body,
	}
end

local function addPage( path, name )
	if not name then
		return
	end

	checkClash( name )

	pages[ name ] = loadPage( path, name )
	pages[ name ].name = name
end

local function addMultiPage( path, name )
	local info = assert( io.contents( "%s/%s.txt" % { path, name } ) )
	local title, files = info:match( "^([^\n]+)%s+(.+)$" )

	local page = {
		name = name,
		title = title,
		pages = { },
	}

	for file in files:gmatch( "([^\n]+)" ) do
		table.insert( page.pages, loadPage( "%s/%s.txt" % { path, file } ) )
	end

	checkClash( name )

	pages[ name ] = page
end

local function addCategory( path, name )
	checkClash( name )

	local description = assert( io.contents( "%s/%s.txt" % { path, name } ) )

	local category = {
		name = name,
		description = description:trim(),
		pages = { },
	}

	for file in lfs.dir( path ) do
		if file ~= "." and file ~= ".." and file ~= name .. ".txt" then
			local fullPath = "%s/%s" % { path, file }
			local attr = lfs.attributes( fullPath )

			file = file:lower()

			if attr.mode == "directory" then
				addMultiPage( fullPath, file )
			else
				file = file:match( "^(.+)%.txt$" )

				addPage( fullPath, file )
			end

			table.insert( category.pages, pages[ file ] )
		end
	end

	table.sortByKey( category.pages, "name" )

	categories[ name ] = category
	table.insert( categoriesList, category )
end

local function buildWiki()
	if not io.readable( "data/wiki" ) then
		return
	end

	for file in lfs.dir( "data/wiki" ) do
		if file ~= "." and file ~= ".." then
			local fullPath = "data/wiki/" .. file
			local attr = lfs.attributes( fullPath )

			file = file:lower()

			if attr.mode == "directory" then
				if io.readable( fullPath .. "/pages.txt" ) then
					addMultiPage( fullPath, file )
				else
					addCategory( fullPath, file )
				end
			else
				local name = file:match( "^(.+)%.txt$" )

				addPage( fullPath, name )
			end
		end
	end

	table.sortByKey( categoriesList, "name" )
end

chat.command( "wiki", "user", {
	[ "^$" ] = function( client )
		local output = "#lwThe wiki is split into the following categories:"

		for _, category in ipairs( categoriesList ) do
			output = output .. "\n    #ly%s #d- %s" % {
				category.name,
				category.description,
			}
		end

		client:msg( "%s", output )
	end,

	[ "^(%S+)$" ] = function( client, name )
		name = name:lower()

		if categories[ name ] then
			local output = "#lwPages in #ly%s#lw:" % name

			for _, page in ipairs( categories[ name ].pages ) do
				output = output .. "\n    #ly%s #d- %s" % {
					page.name,
					page.title,
				}
			end

			client:msg( "%s", output )

			return
		end

		if not pages[ name ] then
			client:msg( "No wiki entry for #ly%s#d.", name )

			return
		end

		if not pages[ name ].pages then
			client:msg( "#lwShowing #ly%s#lw:\n#d%s", name, pages[ name ].body )

			return
		end

		local output = "#ly%s#lw is split into #ly%d#lw pages:" % {
			name,
			#pages[ name ].pages,
		}

		for i, page in ipairs( pages[ name ].pages ) do
			output = output .. "\n    #ly%d #d- %s" % {
				i,
				page.title,
			}
		end

		client:msg( "%s", output )
	end,

	[ "^(%S+)%s+(%d+)$" ] = function( client, name, page )
		name = name:lower()
		page = tonumber( page )
		
		if not pages[ name ] then
			client:msg( "No wiki entry for #ly%s#d.", name )

			return
		end

		if not pages[ name ].pages or not pages[ name ].pages[ page ] then
			client:msg( "#lwBad page number." )

			return
		end

		client:msg( "#lwShowing #ly%s#lw: #d(page #lw%d#d of #lw%d#d)\n%s",
			name,
			page, #pages[ name ].pages,
			pages[ name ].pages[ page ].body
		)
	end,
}, "<category/page> [page] [search]", "Super duper wiki" )

chat.command( "rebuildwiki", "all", function( client )
	categories = { }
	categoriesList = { }
	pages = { }

	local ok, err = pcall( buildWiki )

	if not ok then
		client:msg( "Rebuild failed! %s", err )
	else
		client:msg( "Rebuilt." )
	end
end, "Rebuild the wiki" )

buildWiki()
