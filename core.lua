--- Formats, 7zz, the cache, listings and extraction: what every VFS call needs.

local state = require(".state")
local get_password, unlocked = state.get_password, state.unlocked

local DIR_MODE, FILE_MODE = tonumber("40755", 8), tonumber("100644", 8)

-- The fetcher extracts automatically up to this size; bigger entries are extracted only
-- when opened, so scrolling past a 2 GB video doesn't stall.
local AUTO_EXTRACT_MAX = 64 * 1024 * 1024

-- In an encrypted archive, opening a folder extracts its files up to this much in total.
local ENCRYPTED_FOLDER_MAX = 256 * 1024 * 1024

-- Formats, matched on the lowercased file name. `type` is 7zz's -t for writing; formats
-- without one are read-only (7zz can't write rar, nor delete from tar). `tar` marks a
-- compressed tar: 7zz sees a single inner .tar there, so that is decompressed into the
-- cache once and browsed instead.
local FORMATS = {
	{ "%.zip$", type = "zip" },
	-- Zip under another name. Editing a signed one (apk, ipa, jar) breaks its signature.
	{ "%.jar$", type = "zip" },
	{ "%.war$", type = "zip" },
	{ "%.ear$", type = "zip" },
	{ "%.aar$", type = "zip" },
	{ "%.apk$", type = "zip" },
	{ "%.ipa$", type = "zip" },
	{ "%.xpi$", type = "zip" },
	{ "%.whl$", type = "zip" },
	{ "%.nupkg$", type = "zip" },
	{ "%.vsix$", type = "zip" },
	{ "%.epub$", type = "zip" },
	{ "%.cbz$", type = "zip" },
	{ "%.7z$", type = "7z" },
	{ "%.cb7$", type = "7z" },
	{ "%.rar$" },
	{ "%.cbr$" },
	{ "%.iso$" },
	{ "%.cab$" },
	{ "%.tar$" },
	{ "%.tar%.gz$", tar = true },
	{ "%.tgz$", tar = true },
	{ "%.tar%.bz2$", tar = true },
	{ "%.tbz2?$", tar = true },
	{ "%.tar%.xz$", tar = true },
	{ "%.txz$", tar = true },
	{ "%.tar%.zst$", tar = true },
	{ "%.tzst$", tar = true },
}

local function format_of(path)
	local name = tostring(path):lower()
	for _, f in ipairs(FORMATS) do
		if name:find(f[1]) then
			return f
		end
	end
end

local function writable(archive)
	local f = format_of(archive)
	return f ~= nil and f.type ~= nil
end

local function err(kind, fmt, ...) return Error.fs { kind = kind, message = string.format(fmt, ...) } end

-- Run 7zz; for an archive with a known password, the password goes in on stdin, never on
-- the command line where `ps` would show it. 7zz asks at most twice (to open a 7z with
-- encrypted names, then for what it adds), so it gets three copies.
local function exec(args, archive, cwd)
	local pw = archive and get_password(archive)
	local cmd = Command("7zz"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED)
	if cwd then
		cmd:cwd(cwd)
	end
	local out, e
	if pw then
		local child
		child, e = cmd:stdin(Command.PIPED):spawn()
		if child then
			child:write_all(string.rep(pw .. "\n", 3))
			child:flush()
			out, e = child:wait_with_output()
		end
	else
		out, e = cmd:stdin(Command.NULL):output()
	end
	if not out then
		return nil, err("NotFound", "zipfs needs `7zz` in PATH: %s", e)
	elseif out.status.success then
		return out.stdout
	end
	local text = out.stdout .. out.stderr
	if text:find("Wrong password") then
		return nil, err("PermissionDenied", "Wrong password for %s", archive or "the archive")
	elseif not pw and text:find("Enter password") then
		return nil,
			err("PermissionDenied", "%s is encrypted: press l on it to enter the password", archive or "The archive")
	end
	return nil, err("InvalidData", "7zz failed: %s", out.stderr)
end

local function run(args, archive) return exec(args, archive) end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local s = f:read("a")
	f:close()
	return s
end

local function write_atomic(path, data)
	local tmp = string.format("%s.tmp%d%d", path, os.time(), math.random(1e9))
	local f = io.open(tmp, "wb")
	if not f then
		return false
	end
	f:write(data)
	f:close()
	return os.rename(tmp, path)
end

-- Every provide() call runs in a fresh Lua state, so nothing survives in memory between
-- calls. The listing and extracted files live on disk instead, under a folder keyed by the
-- archive's path, size and mtime, so editing the archive starts a fresh cache.
local function cache_root()
	local base = os.getenv("TMPDIR") or "/tmp/"
	return (base:sub(-1) == "/" and base or base .. "/") .. "yazi-zipfs"
end

-- Cache layout, per archive (<p> = hash of the archive's path):
--   <p><hash of size+mtime>.list  listing of one version of the archive
--   <p>tree/                      extracted entries at their inner paths
--   <p>tree.src                   the archive's path, so a cleanup can save edits first
--   <p><hash of size+mtime>.tar   a compressed tar, decompressed (tar.gz etc. only)
-- The listing is per version. Extracted copies are not: an edit only changes some entries,
-- and Yazi doesn't re-run the fetcher for files it already knows, so throwing them all away
-- on every edit would break previews. Each copy is checked against its entry instead.
local function archive_prefix(archive) return ya.hash(archive) .. "-" end

local function archive_dir(archive)
	local cha, e = fs.cha(Url(archive))
	if not cha then
		return nil, e
	end
	local version = ya.hash(string.format("%d\0%s", cha.len, cha.mtime or 0))
	return string.format("%s/%s%s", cache_root(), archive_prefix(archive), version), cha
end

local function remove_cache(dir)
	fs.remove("dir_all", Url(dir))
	fs.remove("file", Url(dir .. ".list"))
	fs.remove("file", Url(dir .. ".tar"))
end

-- Remove cached versions (listing, decompressed tar) of `archive` other than `keep` (a
-- version path, or nil).
local function prune_versions(archive, keep)
	local root, prefix = cache_root(), archive_prefix(archive)
	for _, f in ipairs(fs.read_dir(Url(root), { resolve = false }) or {}) do
		local name = f.name or ""
		-- A version is 32 hex digits; "tree", "lock" etc. start with a non-hex letter.
		local version = name:sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^(%x+)")
		local dir = version and string.format("%s/%s%s", root, prefix, version)
		if dir and dir ~= keep then
			fs.remove("file", f.url)
			fs.remove("dir_all", f.url)
		end
	end
end

-- Split a mount URL into the archive's real path and the path inside it ("" at the root).
local function locate(url)
	local base = url.base
	if not base then
		return nil, nil, err("InvalidInput", "Not a zipfs URL: %s", url)
	end
	local archive = tostring(base.path):gsub("/+$", "")
	local inner = tostring(url.path):sub(#archive + 1):gsub("^/+", ""):gsub("/+$", "")
	return archive, inner
end

local function parse_time(s)
	local y, mo, d, h, mi, se = (s or ""):match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
	if y then
		return os.time { year = y, month = mo, day = d, hour = h, min = mi, sec = se }
	end
end

-- "drwxr-xr-x" -> numeric mode. Zips made on Windows carry no Unix bits; fall back then.
-- Symlinks inside the archive come out as plain files holding the link target.
local function parse_mode(attrs, is_dir)
	local perm = (attrs or ""):match("[-dl]([-r][-w][-xsS][-r][-w][-xsS][-r][-w][-xtT])")
	if not perm then
		return is_dir and DIR_MODE or FILE_MODE
	end
	local bits = 0
	for i = 1, 9 do
		local c = perm:sub(i, i)
		if c ~= "-" and c ~= "S" and c ~= "T" then
			bits = bits | (1 << (9 - i))
		end
	end
	return (is_dir and tonumber("40000", 8) or tonumber("100000", 8)) | bits
end

-- macOS metadata that Finder's "Compress" adds: a `__MACOSX/` tree and `._name` files
-- (AppleDouble: tags, icons, resource forks). Nobody wants to see them.
local function is_hidden(path)
	return path == "__MACOSX" or path:sub(1, 9) == "__MACOSX/" or (path:match("[^/]+$") or ""):sub(1, 2) == "._"
end

-- `7zz l -slt` -> { entries = { [path] = info }, children = { [dir] = { name, ... } },
-- hidden = { [path] = raw path } }
local function parse_listing(text)
	local entries, children = { [""] = { dir = true, len = 0, mode = DIR_MODE } }, { [""] = {} }
	local hidden, encrypted, aes, locked = {}, false, false, false

	local function add_child(path)
		local parent, name = path:match("^(.*)/([^/]+)$")
		if not parent then
			parent, name = "", path
		end
		children[parent] = children[parent] or {}
		table.insert(children[parent], name)
		return parent
	end

	-- Zips may leave out directory entries ("zip -D"), so missing parents are synthesized.
	local function ensure_dir(path)
		while path ~= "" and not entries[path] do
			entries[path] = { dir = true, len = 0, mode = DIR_MODE }
			children[path] = children[path] or {}
			path = add_child(path)
		end
	end

	for block in (text .. "\n\n"):gmatch("(.-)\n\n") do
		local kv = {}
		for line in block:gmatch("[^\n]+") do
			local k, v = line:match("^(.-) = (.*)$")
			if k then
				kv[k] = v
			end
		end

		-- tar paths often start with "./"; 7zz only matches them spelled that way, so the raw
		-- path is kept for extraction.
		locked = locked or kv.ZipfsLocked == "+"
		encrypted = encrypted or kv.Encrypted == "+"
		aes = aes or (kv.Method or ""):find("AES") ~= nil

		local path = kv.Path
		while path and (path:find("^/") or path:find("^%./")) do
			path = path:gsub("^/+", ""):gsub("^%./+", "")
		end
		path = path and path:gsub("/+$", "")
		if path == "." then
			path = nil
		end
		-- Skip "../" entries: they would let a hostile zip write outside the cache folder.
		local unsafe = path and (path == ".." or path:find("^%.%./") or path:find("/%.%./") or path:find("/%.%.$"))
		if path and path ~= "" and not unsafe and is_hidden(path) then
			hidden[path] = kv.Path
		elseif path and path ~= "" and not unsafe then
			-- 7z listings have no Folder field; the attributes start with "D" instead.
			local is_dir = kv.Folder == "+" or (kv.Folder == nil and (kv.Attributes or ""):find("^D") ~= nil)
			ensure_dir(path:match("^(.*)/[^/]+$") or "")
			if not entries[path] then
				add_child(path)
			end
			if is_dir then
				children[path] = children[path] or {}
			end
			entries[path] = {
				raw = kv.Path,
				encrypted = kv.Encrypted == "+",
				dir = is_dir,
				len = is_dir and 0 or tonumber(kv.Size) or 0,
				mtime = parse_time(kv.Modified),
				mode = parse_mode(kv.Attributes, is_dir),
			}
		end
	end
	return { entries = entries, children = children, hidden = hidden, encrypted = encrypted, aes = aes, locked = locked }
end

local function split(path)
	local parent, name = path:match("^(.*)/([^/]+)$")
	return parent and parent .. "/" or "", name or path
end

-- The hidden metadata that belongs to `path`, so it goes along when `path` is deleted or
-- renamed: `dir/._name`, `__MACOSX/dir/._name` and, for a folder, `__MACOSX/path/...`.
-- Returns { { hidden path, path it moves to when `path` becomes `to` } }, leaving out
-- entries under a folder that is already in the list (7zz takes folders whole).
local function companions(idx, path, to)
	local pp, pn = split(path)
	local tp, tn = split(to or path)
	local out = {}
	for h, raw in pairs(idx.hidden) do
		local moved
		if h == pp .. "._" .. pn then
			moved = tp .. "._" .. tn
		elseif h == "__MACOSX/" .. pp .. "._" .. pn then
			moved = "__MACOSX/" .. tp .. "._" .. tn
		elseif h == "__MACOSX/" .. path or h:sub(1, #path + 10) == "__MACOSX/" .. path .. "/" then
			moved = "__MACOSX/" .. (to or path) .. h:sub(#path + 10)
		end
		if moved then
			out[#out + 1] = { h, moved, raw }
		end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	local kept, last = {}, nil
	for _, c in ipairs(out) do
		if not (last and c[1]:sub(1, #last + 1) == last .. "/") then
			kept[#kept + 1], last = c, c[1]
		end
	end
	return kept
end

-- `args` plus the hidden metadata of `inner`, for `7zz d`.
local function with_companions(args, idx, inner)
	for _, c in ipairs(companions(idx, inner)) do
		args[#args + 1] = c[3]
	end
	return args
end

-- 7zz rewrites the archive on every edit. Deleting a folder makes Yazi send one RemoveFile per
-- file, possibly in parallel, so edits take a per-archive lock (mkdir is atomic). A lock
-- older than LOCK_STALE seconds is assumed to be left over from a crash.
local LOCK_STALE = 600

-- `name` picks a separate lock ("lock" by default) for work that may run while an edit
-- holds the main one.
local function with_lock(archive, fn, name)
	fs.create("dir_all", Url(cache_root()))
	local lock = Url(string.format("%s/%s%s.lock", cache_root(), archive_prefix(archive), name or "lock"))
	local deadline = os.time() + LOCK_STALE
	while not fs.create("dir", lock) do
		local cha = fs.cha(lock)
		if cha and cha.mtime and os.time() - cha.mtime > LOCK_STALE then
			fs.remove("dir", lock)
		elseif os.time() > deadline then
			return nil, err("TimedOut", "Timed out waiting for another edit of %s", archive)
		else
			ya.sleep(0.05)
		end
	end

	local ok, a, b = pcall(fn)
	fs.remove("dir", lock)
	if not ok then
		return nil, err("Other", "%s", a)
	end
	return a, b
end

-- The file 7zz reads for `archive`: the archive itself, or for a compressed tar the tar
-- inside it, decompressed into the cache on first use (tar.gz can't be read selectively).
local function source(archive)
	local fmt = format_of(archive)
	if not (fmt and fmt.tar) then
		return archive
	end
	local dir, cha = archive_dir(archive)
	if not dir then
		return nil, cha
	end
	local tar = dir .. ".tar"
	if fs.cha(Url(tar)) then
		return tar
	end
	return with_lock(archive, function()
		if fs.cha(Url(tar)) then
			return tar -- another call decompressed it while this one waited
		end
		local stage = string.format("%s.x%d%d", tar, os.time(), math.random(1e9))
		local _, e = run { "x", "-y", "-o" .. stage, archive }
		local inner = not e and (fs.read_dir(Url(stage), { resolve = true }) or {})[1]
		if inner and not inner.cha.is_dir then
			os.rename(tostring(inner.url), tar)
		end
		fs.remove("dir_all", Url(stage))
		if fs.cha(Url(tar)) then
			return tar
		end
		return nil, e or err("InvalidData", "%s holds no tar", archive)
	end, "untar")
end

local function index(archive)
	local dir, cha = archive_dir(archive)
	if not dir then
		return nil, cha
	end

	local list_path = dir .. ".list"
	local text = read_file(list_path)
	if not text then
		local src, e = source(archive)
		if not src then
			return nil, e
		end
		text, e = run { "l", "-slt", "-ba", "-sccUTF-8", src }
		if not text and get_password(archive) then
			-- Names are encrypted too (7z -mhe). Remember that, so edits keep them encrypted.
			text, e = run({ "l", "-slt", "-ba", "-sccUTF-8", src }, archive)
			text = text and "ZipfsLocked = +\n\n" .. text
		end
		if not text then
			return nil, e
		end
		fs.create("dir_all", Url(cache_root()))
		write_atomic(list_path, text)
		write_atomic(string.format("%s/%stree.src", cache_root(), archive_prefix(archive)), archive)
		prune_versions(archive, dir) -- first sight of this version: drop the older ones
	end

	local idx = parse_listing(text)
	idx.dir = dir
	idx.tree = string.format("%s/%stree", cache_root(), archive_prefix(archive))
	idx.entries[""].mtime = cha.mtime -- the archive root looks as new as the archive itself
	local unlocked = fs.cha(Url(string.format("%s/%spid", cache_root(), archive_prefix(archive))))
	idx.gen = unlocked and unlocked.mtime
	return idx
end

local function lookup(url)
	local archive, inner, e = locate(url)
	if not archive then
		return nil, e
	end
	local idx, e = index(archive)
	if not idx then
		return nil, e
	end
	local info = idx.entries[inner]
	if not info then
		return nil, err("NotFound", "No such entry in %s: %s", archive, inner)
	end
	return info, idx, archive, inner
end

local function make_file(url, idx, inner)
	local info, name = idx.entries[inner], url.name or ""
	local cha = Cha {
		kind = name:sub(1, 1) == "." and 2 or 0,
		mode = info.mode,
		len = info.len,
		mtime = info.mtime,
		-- Each unlock of an encrypted archive is a new generation: its copies were deleted
		-- when it was last locked, and a changed ctime makes Yazi fetch them again.
		ctime = idx.gen or info.mtime,
	}
	local backing = inner == "" and idx.tree or idx.tree .. "/" .. inner
	return File { url = url, cha = cha, backing = Path.os(backing) }, cha
end

-- A copy is current when size and mtime match its entry (7zz sets the entry's mtime on
-- extract; zip stores DOS times with 2 s steps, hence the slack).
local function extracted(path, info)
	local cha = fs.cha(Url(path))
	if not cha or cha.len ~= info.len then
		return false
	end
	return not (cha.mtime and info.mtime) or math.abs(cha.mtime - info.mtime) <= 2
end

-- A copy newer than its entry was edited through an opener and must be saved back, never
-- re-extracted over. (Extracting sets the entry's mtime, and the copy is renamed into place,
-- so nothing but an edit makes it newer.)
local function edited(path, info)
	if info.dir or not info.mtime then
		return false
	end
	local cha = fs.cha(Url(path))
	return cha ~= nil and cha.mtime ~= nil and cha.mtime > info.mtime + 2
end

-- Extract the given entries of one archive into its cache folder with a single 7zz run.
-- -spd turns off wildcard matching, so names like "big [1].txt" are taken literally.
local function extract_many(archive, idx, inners)
	local todo = {}
	for _, inner in ipairs(inners) do
		local info = idx.entries[inner]
		local path = idx.tree .. "/" .. inner
		if info and not info.dir and not extracted(path, info) and not edited(path, info) then
			todo[#todo + 1] = inner
		end
	end
	if #todo == 0 then
		return true
	end

	-- Extract next to the tree, then rename into place: 7zz rewrites files in place, and a
	-- preview reading the old copy at that moment would fail.
	local src, e = source(archive)
	if not src then
		return false, e
	end
	local stage = string.format("%s.x%d%d", idx.tree, os.time(), math.random(1e9))
	local args = { "x", "-y", "-spd", "-sccUTF-8", "-o" .. stage, src, "--" }
	for _, inner in ipairs(todo) do
		args[#args + 1] = idx.entries[inner].raw or inner
	end
	local _, e = run(args, archive)
	if not e then
		for _, inner in ipairs(todo) do
			local to = Url(idx.tree .. "/" .. inner)
			fs.create("dir_all", to.parent)
			os.rename(stage .. "/" .. inner, tostring(to))
		end
	end
	fs.remove("dir_all", Url(stage))
	return e == nil, e
end

local function extract(url)
	local info, idx, archive, inner = lookup(url)
	if not info then
		return nil, idx
	elseif info.dir then
		return nil, err("IsADirectory", "Is a directory: %s", inner)
	end

	local path = idx.tree .. "/" .. inner
	if edited(path, info) then
		return path -- not saved back yet; this copy is the newest content
	end
	local ok, e = extract_many(archive, idx, { inner })
	if not ok then
		return nil, e
	elseif not extracted(path, info) then
		return nil, err("InvalidData", "Could not extract %s (encrypted entry?)", inner)
	end
	return path
end

return {
	DIR_MODE = DIR_MODE,
	FILE_MODE = FILE_MODE,
	AUTO_EXTRACT_MAX = AUTO_EXTRACT_MAX,
	ENCRYPTED_FOLDER_MAX = ENCRYPTED_FOLDER_MAX,
	FORMATS = FORMATS,
	format_of = format_of,
	writable = writable,
	err = err,
	exec = exec,
	run = run,
	read_file = read_file,
	write_atomic = write_atomic,
	cache_root = cache_root,
	archive_prefix = archive_prefix,
	archive_dir = archive_dir,
	remove_cache = remove_cache,
	prune_versions = prune_versions,
	locate = locate,
	parse_time = parse_time,
	parse_mode = parse_mode,
	is_hidden = is_hidden,
	parse_listing = parse_listing,
	split = split,
	companions = companions,
	with_companions = with_companions,
	LOCK_STALE = LOCK_STALE,
	with_lock = with_lock,
	source = source,
	index = index,
	lookup = lookup,
	make_file = make_file,
	extracted = extracted,
	edited = edited,
	extract_many = extract_many,
	extract = extract,
}
