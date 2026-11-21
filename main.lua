--- Browse zip archives as folders through Yazi's custom VFS (kind = "mount").
---
--- Listing, extraction and edits go through `7zz`, which keeps non-ASCII names intact
--- (macOS `zipinfo`/`unzip` turn them into "????").
---
--- Supported edits: trash, delete, rename, new folder, new file, paste into the zip. Each one
--- rewrites the whole zip (that is how zip works), so they are serialized per archive with a
--- lock.
---
--- Opened files are saved back too. The opener gets the extracted copy, and Yazi's own
--- `upload` (which syncs a cache copy back) only works for SFTP, so zipfs does it itself: a
--- copy newer than its entry has been edited, and the next time Yazi looks at its folder
--- (refresh, focus, cd) it is added back into the zip.
---
--- Entries are extracted into a cache folder and every File points its `backing` at the
--- extracted copy. Yazi 26.9.1 refuses to `download` from mount URLs ("Cannot download
--- non-remote file"), but `backing` is what previewers, `file --mime-type` and opener `%s`
--- read, so this is what makes preview and open work.

local M = {}

local SCHEME, DOMAIN = "archive", "zip"
local DIR_MODE, FILE_MODE = tonumber("40755", 8), tonumber("100644", 8)

-- The fetcher extracts automatically up to this size; bigger entries are extracted only
-- when opened, so scrolling past a 2 GB video doesn't stall.
local AUTO_EXTRACT_MAX = 64 * 1024 * 1024

local function err(kind, fmt, ...) return Error.fs { kind = kind, message = string.format(fmt, ...) } end

local function run(args)
	local out, e = Command("7zz"):arg(args):stdin(Command.NULL):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then
		return nil, err("NotFound", "zipfs needs `7zz` in PATH: %s", e)
	elseif not out.status.success then
		return nil, err("InvalidData", "7zz failed: %s", out.stderr)
	end
	return out.stdout
end

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
end

-- Remove cached listings of `archive` other than `keep` (a version path, or nil).
local function prune_versions(archive, keep)
	local files = fs.read_dir(Url(cache_root()), { resolve = false })
	local prefix = archive_prefix(archive)
	for _, f in ipairs(files or {}) do
		local name = f.name or ""
		local dir = tostring(f.url):gsub("%.list$", "")
		local own = name:sub(1, #prefix) == prefix
		if own and dir ~= keep and not name:find("%.lock$") and not name:find("tree") then
			remove_cache(dir)
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

-- `7zz l -slt` -> { entries = { [path] = info }, children = { [dir] = { name, ... } } }
local function parse_listing(text)
	local entries, children = { [""] = { dir = true, len = 0, mode = DIR_MODE } }, { [""] = {} }

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

		local path = kv.Path and kv.Path:gsub("^/+", ""):gsub("/+$", "")
		-- Skip "../" entries: they would let a hostile zip write outside the cache folder.
		local unsafe = path and (path == ".." or path:find("^%.%./") or path:find("/%.%./") or path:find("/%.%.$"))
		if path and path ~= "" and not unsafe then
			local is_dir = kv.Folder == "+"
			ensure_dir(path:match("^(.*)/[^/]+$") or "")
			if not entries[path] then
				add_child(path)
			end
			if is_dir then
				children[path] = children[path] or {}
			end
			entries[path] = {
				dir = is_dir,
				len = is_dir and 0 or tonumber(kv.Size) or 0,
				mtime = parse_time(kv.Modified),
				mode = parse_mode(kv.Attributes, is_dir),
			}
		end
	end
	return { entries = entries, children = children }
end

local function index(archive)
	local dir, cha = archive_dir(archive)
	if not dir then
		return nil, cha
	end

	local list_path = dir .. ".list"
	local text = read_file(list_path)
	if not text then
		local e
		text, e = run { "l", "-slt", "-ba", "-sccUTF-8", archive }
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
	local stage = string.format("%s.x%d%d", idx.tree, os.time(), math.random(1e9))
	local args = { "x", "-y", "-spd", "-sccUTF-8", "-o" .. stage, archive, "--" }
	for _, inner in ipairs(todo) do
		args[#args + 1] = inner
	end
	local _, e = run(args)
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

-- 7zz rewrites the zip on every edit. Deleting a folder makes Yazi send one RemoveFile per
-- file, possibly in parallel, so edits take a per-archive lock (mkdir is atomic). A lock
-- older than LOCK_STALE seconds is assumed to be left over from a crash.
local LOCK_STALE = 600

local function with_lock(archive, fn)
	fs.create("dir_all", Url(cache_root()))
	local lock = Url(string.format("%s/%slock.lock", cache_root(), archive_prefix(archive)))
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

-- Run a 7zz command that changes the archive, under the lock. `check(idx)` runs on a fresh
-- listing inside the lock and returns the 7zz args, or nil plus an Error to refuse.
local function mutate(archive, check)
	return with_lock(archive, function()
		local idx, e = index(archive)
		if not idx then
			return false, e
		end
		local args, cwd
		args, e, cwd = check(idx)
		if not args then
			return false, e
		end

		local cmd = Command("7zz"):arg(args):stdin(Command.NULL):stdout(Command.PIPED):stderr(Command.PIPED)
		if cwd then
			cmd:cwd(cwd)
		end
		local out, e = cmd:output()
		if not out then
			return false, err("NotFound", "zipfs needs `7zz` in PATH: %s", e)
		elseif not out.status.success then
			return false, err("Other", "7zz failed: %s", out.stderr)
		end
		remove_cache(idx.dir) -- the archive changed, so this version's listing is dead
		return true
	end)
end

local function inner_of(archive, path)
	path = tostring(path)
	if path:sub(1, #archive + 1) ~= archive .. "/" then
		return nil
	end
	local inner = path:sub(#archive + 2):gsub("^/+", ""):gsub("/+$", "")
	return inner ~= "" and inner or nil
end

local function remove(url, mode)
	local archive, inner, e = locate(url)
	if not archive then
		return false, e
	elseif inner == "" then
		return false, err("PermissionDenied", "Cannot remove the archive root")
	end
	return mutate(archive, function(idx)
		local info = idx.entries[inner]
		if not info then
			return nil, err("NotFound", "No such entry: %s", inner)
		elseif mode == "file" and info.dir then
			return nil, err("IsADirectory", "Is a directory: %s", inner)
		elseif mode == "dir" and not info.dir then
			return nil, err("NotADirectory", "Not a directory: %s", inner)
		elseif mode == "dir" and #(idx.children[inner] or {}) > 0 then
			return nil, err("DirectoryNotEmpty", "Directory not empty: %s", inner)
		end
		return { "d", "-spd", "-sccUTF-8", archive, "--", inner }
	end)
end

local function rename(from, to)
	local archive, src, e = locate(from)
	if not archive then
		return false, e
	end
	local dst = inner_of(archive, to)
	if src == "" or not dst then
		return false, err("CrossesDevices", "Can only rename within the same archive")
	elseif dst == src or dst:sub(1, #src + 1) == src .. "/" then
		return false, err("InvalidInput", "Cannot move %s into itself", src)
	end

	return mutate(archive, function(idx)
		if not idx.entries[src] then
			return nil, err("NotFound", "No such entry: %s", src)
		elseif idx.entries[dst] then
			-- Yazi asks before overwriting; refusing here keeps a stray call from losing data.
			return nil, err("AlreadyExists", "Already exists: %s", dst)
		end
		local parent = dst:match("^(.*)/[^/]+$")
		if parent and not (idx.entries[parent] and idx.entries[parent].dir) then
			return nil, err("NotFound", "No such directory: %s", parent)
		end
		-- 7zz renames a folder together with everything under it.
		return { "rn", "-spd", "-sccUTF-8", archive, "--", src, dst }
	end)
end

local function create_dir(url)
	local archive, inner, e = locate(url)
	if not archive then
		return false, e
	elseif inner == "" then
		return false, err("AlreadyExists", "Already exists: %s", archive)
	end

	-- 7zz can only add what exists on disk, so stage an empty folder at the same path.
	local stage = string.format("%s/stage-%d%d", cache_root(), os.time(), math.random(1e9))
	local ok, e = mutate(archive, function(idx)
		if idx.entries[inner] then
			return nil, err("AlreadyExists", "Already exists: %s", inner)
		end
		local parent = inner:match("^(.*)/[^/]+$")
		if parent and not (idx.entries[parent] and idx.entries[parent].dir) then
			return nil, err("NotFound", "No such directory: %s", parent)
		end
		local made, e = fs.create("dir_all", Url(stage .. "/" .. inner))
		if not made then
			return nil, e
		end
		return { "a", "-tzip", "-spd", "-sccUTF-8", archive, "--", inner }, nil, stage
	end)
	fs.remove("dir_all", Url(stage))
	return ok, e
end

-- --- Writing files (paste into the zip, `a` for a new file)
--
-- Yazi writes a file as: Open(create/truncate) -> SetLen(final size) -> up to 4 parallel
-- Write(offset, bytes) -> SetAttrs. There is no Close, and SetAttrs errors are ignored, so
-- the zip is updated inside the Write that completes the file: a failure there fails the
-- copy, and a move then keeps its source. Chunks are staged on disk because every call gets
-- a fresh Lua state.

local function stage_paths(archive, inner)
	local dir = string.format("%s/writes/%s%s", cache_root(), archive_prefix(archive), ya.hash(inner))
	return dir, dir .. "/tree", dir .. "/meta"
end

local function read_meta(meta)
	local s = read_file(meta)
	if not s then
		return nil
	end
	local expected, received = s:match("^(%-?%d+) (%d+)")
	return tonumber(expected), tonumber(received)
end

local function write_meta(meta, expected, received) return write_atomic(meta, string.format("%d %d", expected, received)) end

local function seven(args, cwd)
	local cmd = Command("7zz"):arg(args):stdin(Command.NULL):stdout(Command.PIPED):stderr(Command.PIPED)
	if cwd then
		cmd:cwd(cwd)
	end
	local out, e = cmd:output()
	if not out then
		return false, err("NotFound", "zipfs needs `7zz` in PATH: %s", e)
	elseif not out.status.success then
		return false, err("Other", "7zz failed: %s", out.stderr)
	end
	return true
end

-- Add (or replace) <tree>/<inner> as <inner> in the zip. Caller holds the lock.
local function add_from(archive, idx, inner, tree)
	local ok, e = seven({ "a", "-tzip", "-spd", "-sccUTF-8", archive, "--", inner }, tree)
	if ok then
		remove_cache(idx.dir)
	end
	return ok, e
end

-- Saving opened files back. `inners` = nil checks every entry.
local function edited_among(idx, inners)
	local out = {}
	if not inners then
		inners = {}
		for inner in pairs(idx.entries) do
			inners[#inners + 1] = inner
		end
	end
	for _, inner in ipairs(inners) do
		local info = idx.entries[inner]
		if info and edited(idx.tree .. "/" .. inner, info) then
			out[#out + 1] = inner
		end
	end
	return out
end

-- Add edited copies back into the zip in one 7zz run. Returns the names it saved.
local function write_back(archive, inners)
	return with_lock(archive, function()
		local idx, e = index(archive)
		if not idx then
			return nil, e
		end
		local todo = edited_among(idx, inners) -- again, inside the lock
		if #todo == 0 then
			return todo
		end
		local args = { "a", "-tzip", "-spd", "-sccUTF-8", archive, "--" }
		for _, inner in ipairs(todo) do
			args[#args + 1] = inner
		end
		local ok, e = seven(args, idx.tree)
		if not ok then
			return nil, e
		end
		remove_cache(idx.dir)
		return todo
	end)
end

-- Save edited copies among `inners` (all entries when nil). Returns the index to use from
-- here on and whether the zip changed. A failure is shown, and the copy stays edited, so the
-- next look tries again.
local function settle(archive, idx, inners)
	if #edited_among(idx, inners) == 0 then
		return idx, false
	end
	local saved, e = write_back(archive, inners)
	if not saved then
		ya.notify { title = "zipfs", content = "Could not save into the zip: " .. tostring(e), level = "error", timeout = 8 }
		return idx, false
	end
	return index(archive) or idx, #saved > 0
end

local function child_inners(idx, inner)
	local out = {}
	for _, name in ipairs(idx.children[inner] or {}) do
		out[#out + 1] = inner == "" and name or inner .. "/" .. name
	end
	return out
end

local function finish_if_complete(archive, inner)
	local dir, tree, meta = stage_paths(archive, inner)
	local expected, received = read_meta(meta)
	if not expected or expected < 0 or received < expected then
		return true
	end
	local idx, e = index(archive)
	if not idx then
		return false, e
	end
	local ok, e = add_from(archive, idx, inner, tree)
	fs.remove("dir_all", Url(dir))
	return ok, e
end

local function open_write(url, d)
	local archive, inner, e = locate(url)
	if not archive then
		return nil, e
	elseif inner == "" then
		return nil, err("IsADirectory", "Is a directory: %s", archive)
	elseif d.append then
		return nil, err("Unsupported", "zipfs cannot append to files")
	end

	return with_lock(archive, function()
		local idx, e = index(archive)
		if not idx then
			return nil, e
		end
		local info = idx.entries[inner]
		local parent = inner:match("^(.*)/[^/]+$")
		local dir, tree, meta = stage_paths(archive, inner)

		if info and info.dir then
			return nil, err("IsADirectory", "Is a directory: %s", inner)
		elseif d.create_new and info then
			return nil, err("AlreadyExists", "Already exists: %s", inner)
		elseif parent and not (idx.entries[parent] and idx.entries[parent].dir) then
			return nil, err("NotFound", "No such directory: %s", parent)
		elseif not (d.create or d.create_new or d.truncate) then
			-- Another chunk handle of a write already in progress.
			if read_meta(meta) then
				return 0
			end
			return nil, err("Unsupported", "zipfs can only write whole new files, not edit in place")
		elseif not info and not (d.create or d.create_new) then
			return nil, err("NotFound", "No such entry: %s", inner)
		end

		fs.remove("dir_all", Url(dir))
		local file = tree .. "/" .. inner
		fs.create("dir_all", Url(file).parent or Url(tree))
		if not write_atomic(file, "") or not write_meta(meta, -1, 0) then
			return nil, err("Other", "Cannot stage %s", inner)
		end

		-- `a` reads the new file back right after creating it, so a new entry has to exist
		-- now. An existing one is left alone until the new content is complete.
		if not info then
			local ok, e = add_from(archive, idx, inner, tree)
			if not ok then
				return nil, e
			end
		end
		return 0
	end)
end

local function set_len(url, size)
	local archive, inner, e = locate(url)
	if not archive then
		return false, e
	end
	return with_lock(archive, function()
		local _, _, meta = stage_paths(archive, inner)
		local expected, received = read_meta(meta)
		if not expected then
			return false, err("Unsupported", "zipfs can only write whole new files, not edit in place")
		end
		write_meta(meta, size, received)
		return finish_if_complete(archive, inner)
	end)
end

local function write_chunk(url, offset, bytes)
	local archive, inner, e = locate(url)
	if not archive then
		return false, e
	end
	return with_lock(archive, function()
		local _, tree, meta = stage_paths(archive, inner)
		local expected, received = read_meta(meta)
		if not expected then
			return false, err("Unsupported", "zipfs can only write whole new files, not edit in place")
		end

		local f = io.open(tree .. "/" .. inner, "r+b")
		if not f then
			return false, err("NotFound", "Staged file vanished: %s", inner)
		end
		f:seek("set", offset)
		f:write(bytes)
		f:close()

		write_meta(meta, expected, received + #bytes)
		return finish_if_complete(archive, inner)
	end)
end

-- Trash = extract the item, move the copy to the macOS Trash, then delete it from the zip.
-- It stays recoverable from the Trash as a normal file/folder.
local function trash(url)
	local archive, inner, e = locate(url)
	if not archive then
		return false, e
	elseif inner == "" then
		return false, err("PermissionDenied", "Cannot trash the archive root")
	end

	local stage = string.format("%s/stage-%d%d", cache_root(), os.time(), math.random(1e9))
	local ok, e = mutate(archive, function(idx)
		local info = idx.entries[inner]
		if not info then
			return nil, err("NotFound", "No such entry: %s", inner)
		end

		local _, e = run { "x", "-y", "-spd", "-sccUTF-8", "-o" .. stage, archive, "--", inner }
		if e then
			return nil, e
		end
		-- A folder that only exists implicitly in the zip may not have been created.
		local copy = stage .. "/" .. inner
		if info.dir then
			fs.create("dir_all", Url(copy))
		elseif not fs.cha(Url(copy)) then
			return nil, err("InvalidData", "Could not extract %s (encrypted entry?)", inner)
		end

		local out, e = Command("trash"):arg({ copy }):stdin(Command.NULL):stderr(Command.PIPED):output()
		if not out then
			return nil, err("NotFound", "Cannot run `trash`: %s", e)
		elseif not out.status.success then
			return nil, err("Other", "trash failed: %s", out.stderr)
		end
		return { "d", "-spd", "-sccUTF-8", archive, "--", inner }
	end)
	fs.remove("dir_all", Url(stage))
	return ok, e
end

function M:provide(job)
	local op = job.op

	if op == "Capabilities" then
		return { symlink = false, hard_link = false, trash = true, copy_progressive = false }
	elseif op == "Absolute" or op == "Canonicalize" then
		return fs.clean_url(job.url)
	elseif op == "Casefold" then
		-- Must fail for a missing path: `a docs/new.txt` only creates `docs` when it does.
		local info, e = lookup(job.url)
		return info and job.url, e
	elseif op == "Metadata" or op == "SymlinkMetadata" then
		local info, idx, _, inner = lookup(job.url)
		if not info then
			return nil, idx
		end
		local _, cha = make_file(job.url, idx, inner)
		return cha
	elseif op == "File" then
		local info, idx, archive, inner = lookup(job.url)
		if not info then
			return nil, idx
		end
		idx = settle(archive, idx, { inner })
		info = idx.entries[inner] or info
		-- After a paste Yazi refreshes the pasted file through here and previews it at once,
		-- before any ReadDir, so a copy extracted from the old entry is refreshed here too.
		local path = idx.tree .. "/" .. inner
		if not info.dir and fs.cha(Url(path)) and not extracted(path, info) then
			extract_many(archive, idx, { inner })
		end
		return (make_file(job.url, idx, inner))
	elseif op == "Revalidate" then
		-- Returning a File means "changed, reload it", nil means "unchanged". The first call
		-- carries a placeholder File, so this is also what triggers the first ReadDir.
		-- Yazi revalidates the folders on screen on refresh, focus and cd, which makes this the
		-- place where files edited through an opener get saved back.
		local url = job.file.url
		local info, idx, archive, inner = lookup(url)
		if not info then
			return nil, idx
		end
		local saved = false
		if info.dir then
			idx, saved = settle(archive, idx, child_inners(idx, inner))
		end
		local new, cha = make_file(url, idx, inner)
		local old = job.file.cha
		if saved or old.mtime ~= cha.mtime or old.len ~= cha.len or old.mode ~= cha.mode then
			return new
		end
		return nil
	elseif op == "ReadDir" then
		local info, idx, archive, inner = lookup(job.url)
		if not info then
			return nil, idx
		elseif not info.dir then
			return nil, err("NotADirectory", "Not a directory: %s", inner)
		end
		idx = settle(archive, idx, child_inners(idx, inner))

		local list, stale = {}, {}
		for _, name in ipairs(idx.children[inner] or {}) do
			local child = inner == "" and name or inner .. "/" .. name
			local file, cha = make_file(job.url:join(name), idx, child)
			list[#list + 1] = { file = file, cha = cha }

			-- A copy extracted before the entry was replaced. Yazi won't run the fetcher again
			-- for a file it already knows, so refresh it here or the preview stays old.
			local info = idx.entries[child]
			local path = idx.tree .. "/" .. child
			if not info.dir and fs.cha(Url(path)) and not extracted(path, info) then
				stale[#stale + 1] = child
			end
		end
		if #stale > 0 then
			extract_many(archive, idx, stale)
		end
		return list
	elseif op == "Open" then
		local d = job.demand
		if d.write or d.append or d.create or d.create_new or d.truncate then
			return open_write(job.url, d)
		end
		-- Read: used when copying out of the archive (yank inside, paste outside).
		local path, e = extract(job.url)
		return path and 0, e
	elseif op == "Read" then
		local path, e = extract(job.url)
		if not path then
			return nil, e
		end
		local f = io.open(path, "rb")
		if not f then
			return nil, err("NotFound", "Cache file vanished: %s", path)
		end
		f:seek("set", job.offset)
		local bytes = f:read(job.len) or ""
		f:close()
		return bytes
	elseif op == "RemoveFile" then
		return remove(job.url, "file")
	elseif op == "RemoveDir" then
		return remove(job.url, "dir")
	elseif op == "RemoveDirAll" then
		return remove(job.url, "all")
	elseif op == "Rename" then
		return rename(job.from, job.to)
	elseif op == "CreateDir" then
		return create_dir(job.url)
	elseif op == "Trash" then
		return trash(job.url)
	elseif op == "SetLen" then
		return set_len(job.url, job.size)
	elseif op == "Write" then
		return write_chunk(job.url, job.offset, job.bytes)
	elseif op == "SetAttrs" then
		return true -- zip keeps no attributes worth setting here; Yazi ignores the result anyway
	end

	return false, err("Unsupported", "zipfs does not support %s", op)
end

-- Fetcher for `archive://*`: extract the files Yazi is asking about, then let the stock
-- `mime.local` fetcher run `file` on the extracted copies (File.path is the backing path).
function M:fetch(job)
	local groups, big = {}, {}
	for _, file in ipairs(job.files) do
		if file.cha.len > AUTO_EXTRACT_MAX then
			big[#big + 1] = file
		elseif not file.cha.is_dir then
			local archive, inner = locate(file.url)
			if archive then
				groups[archive] = groups[archive] or {}
				table.insert(groups[archive], inner)
			end
		end
	end

	for archive, inners in pairs(groups) do
		local idx = index(archive)
		if idx then
			local ok, e = extract_many(archive, idx, inners)
			if not ok then
				ya.err("zipfs: " .. tostring(e))
			end
		end
	end

	local rest = {}
	for _, file in ipairs(job.files) do
		if file.cha.len <= AUTO_EXTRACT_MAX then
			rest[#rest + 1] = file
		end
	end

	return ya.co(function()
		for _, file in ipairs(big) do
			coroutine.yield(file, { "application/octet-stream" })
		end
		if #rest > 0 then
			local next = require("mime.local"):fetch(ya.dict_merge(job, { files = rest }))
			local file, result = next()
			while file do
				file, result = next(coroutine.yield(file, result))
			end
		end
	end)
end

local hovered = ya.sync(function()
	local f = cx.active.current.hovered
	return f
		and {
			url = tostring(f.url),
			is_regular = f.url.spec.is_regular,
			in_zip = f.url.spec.scheme == SCHEME,
			ext = f.url.ext,
			is_dir = f.cha.is_dir,
		}
end)

-- Cache folders and listings not used for this long are removed when you enter a zip.
local CACHE_MAX_AGE = 7 * 24 * 3600

local function cache_entries()
	local out = {}
	-- resolve = true: without it the entries carry no mtime, and everything looks ancient.
	for _, f in ipairs(fs.read_dir(Url(cache_root()), { resolve = true }) or {}) do
		out[#out + 1] = { url = f.url, name = f.name or "", cha = f.cha }
	end
	return out
end

-- Edits in progress own a .lock folder, stage-* folders and writes/; leave those alone.
local function busy(e)
	return e.name:find("%.lock$") or e.name:find("^stage%-") or e.name:find("tree%.x%d+$") or e.name == "writes"
end

-- Before an archive's extracted copies are deleted, save the edited ones into the zip.
-- False means some could not be saved, so the copies must stay.
local function save_tree(prefix)
	local archive = read_file(string.format("%s/%stree.src", cache_root(), prefix))
	if not archive or not fs.cha(Url(archive)) then
		return true -- the zip is gone; nothing to save into
	end
	local idx = index(archive)
	if not idx then
		return false
	end
	idx = settle(archive, idx, nil)
	return #edited_among(idx, nil) == 0
end

-- Delete cache entries `doomed` approves, saving edits first. A tree.src goes only with its
-- tree. Returns how many entries were kept because their edits could not be saved.
local function delete_entries(entries, doomed)
	local kept = 0
	for _, e in ipairs(entries) do
		local prefix = e.name:match("^(%x+%-)tree$")
		if not e.name:find("%.src$") and doomed(e) then
			if prefix and not save_tree(prefix) then
				kept = kept + 1
			else
				fs.remove(e.cha.is_dir and "dir_all" or "file", e.url)
			end
		end
	end
	for _, e in ipairs(entries) do
		local prefix = e.name:match("^(%x+%-)tree%.src$")
		if prefix and doomed(e) and not fs.cha(Url(string.format("%s/%stree", cache_root(), prefix))) then
			fs.remove("file", e.url)
		end
	end
	return kept
end

local function prune_old()
	-- Last use of an archive = newest mtime among its listings (entering a zip touches it).
	local now, used = os.time(), {}
	local entries = cache_entries()
	for _, e in ipairs(entries) do
		local prefix = e.name:match("^(%x+%-).*%.list$")
		if prefix then
			used[prefix] = math.max(used[prefix] or 0, e.cha.mtime or 0)
		end
	end
	delete_entries(entries, function(e)
		local prefix = e.name:match("^(%x+%-)")
		-- An edit briefly leaves an archive with no listing, so the entry's own mtime counts too.
		local last = math.max(prefix and used[prefix] or 0, e.cha.mtime or now)
		return not busy(e) and now - last > CACHE_MAX_AGE
	end)
end

-- Mark a cached archive version as used now, so prune_old keeps it.
local function touch(archive)
	local dir = archive_dir(archive)
	if dir and fs.cha(Url(dir .. ".list")) then
		Command("touch"):arg({ dir .. ".list" }):stdin(Command.NULL):output()
	end
end

-- The archive the active tab is inside, if any.
local current_archive = ya.sync(function()
	local cwd = cx.active.current.cwd
	if cwd.spec.scheme == SCHEME and cwd.base then
		return (tostring(cwd.base.path):gsub("/+$", ""))
	end
end)

local function clean()
	local root = cache_root()
	-- Yazi doesn't re-detect MIME types after a clean, so previews in the zip you're in would
	-- point at deleted copies. Keep that one.
	local here = current_archive()
	local keep = here and archive_prefix(here)
	local out = Command("du"):arg({ "-sk", root }):stdout(Command.PIPED):stderr(Command.NULL):output()
	local kib = out and tonumber(out.stdout:match("^(%d+)")) or 0

	local entries, locked = cache_entries(), false
	for _, e in ipairs(entries) do
		locked = locked or e.name:find("%.lock$") ~= nil
	end

	local skipped = 0
	local unsaved = delete_entries(entries, function(e)
		if e.name == "writes" then
			return not locked -- no edit running, so these are leftovers
		elseif busy(e) then
			skipped = skipped + 1
			return false
		end
		return not (keep and e.name:sub(1, #keep) == keep) -- keep the zip you're in
	end)

	out = Command("du"):arg({ "-sk", root }):stdout(Command.PIPED):stderr(Command.NULL):output()
	kib = kib - (out and tonumber(out.stdout:match("^(%d+)")) or 0)

	local msg = string.format("Freed %.1f MB.", kib / 1024)
	if keep then
		msg = msg .. " Kept the zip you're in."
	end
	if skipped > 0 then
		msg = msg .. " An edit is in progress; its files were kept."
	end
	if unsaved > 0 then
		msg = msg .. " Edited files that could not be saved into their zip were kept."
	end
	ya.notify { title = "zipfs cache", content = msg, timeout = 4, level = unsaved > 0 and "warn" or "info" }
end

-- `plugin zipfs clean` empties the cache. Otherwise, like smart-enter: zip -> browse
-- inside, directory -> enter, other file -> open.
function M:entry(job)
	if job.args[1] == "clean" then
		return clean()
	end

	local h = hovered()
	local ext = h and h.ext and h.ext:lower()

	if h and h.is_regular and (ext == "zip" or ext == "jar") then
		touch(h.url)
		-- Edits left from an earlier visit, in folders Yazi won't look at by itself.
		local idx = index(h.url)
		if idx then
			settle(h.url, idx, nil)
		end
		prune_old()
		ya.emit("cd", { Url(string.format("%s://%s/%s", SCHEME, DOMAIN, h.url)) })
		return
	elseif h and h.in_zip and not h.is_dir then
		-- Files over AUTO_EXTRACT_MAX were skipped by the fetcher; extract before opening.
		local _, e = extract(Url(h.url))
		if e then
			return ya.notify { title = "zipfs", content = tostring(e), level = "error", timeout = 5 }
		end
	end
	ya.emit(h and h.is_dir and "enter" or "open", { hovered = true })
end

return M
