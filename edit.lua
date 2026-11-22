--- Changing archives: delete, rename, new folders, pasted files, trash, saving edits back.

local state = require(".state")
local get_password = state.get_password
local core = require(".core")
local format_of, writable, err, exec, run = core.format_of, core.writable, core.err, core.exec, core.run
local read_file, write_atomic, cache_root, archive_prefix, remove_cache =
  core.read_file, core.write_atomic, core.cache_root, core.archive_prefix, core.remove_cache
local locate, companions, with_companions, with_lock, index =
  core.locate, core.companions, core.with_companions, core.with_lock, core.index
local edited = core.edited

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

    local _, e = exec(args, archive, cwd)
    if e then
      return false, e
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
    return with_companions({ "d", "-spd", "-sccUTF-8", archive, "--", inner }, idx, inner)
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
    local args = { "rn", "-spd", "-sccUTF-8", archive, "--", src, dst }
    for _, c in ipairs(companions(idx, src, dst)) do
      args[#args + 1], args[#args + 2] = c[3], c[2]
    end
    return args
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
    return { "a", "-t" .. format_of(archive).type, "-spd", "-sccUTF-8", archive, "--", inner }, nil, stage
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

local function write_meta(meta, expected, received)
  return write_atomic(meta, string.format("%d %d", expected, received))
end

-- `7zz a` args that keep an encrypted archive encrypted the same way: new entries get the
-- password, AES zips stay AES (7zz's zip default is ZipCrypto), and a 7z with encrypted
-- names keeps them encrypted.
local function add_args(archive, idx)
  local kind = format_of(archive).type
  local args = { "a", "-t" .. kind, "-spd", "-sccUTF-8" }
  if idx.encrypted or idx.locked then
    if not get_password(archive) then
      return nil, err("PermissionDenied", "%s is encrypted: press l on it to enter the password first", archive)
    end
    args[#args + 1] = "-p"
    if kind == "zip" and idx.aes then
      args[#args + 1] = "-mem=AES256"
    elseif kind == "7z" and idx.locked then
      args[#args + 1] = "-mhe=on"
    end
  end
  args[#args + 1] = archive
  args[#args + 1] = "--"
  return args
end

local function seven(args, cwd, archive)
  local _, e = exec(args, archive, cwd)
  return e == nil, e
end

-- Add (or replace) <tree>/<inner> as <inner> in the zip. Caller holds the lock.
local function add_from(archive, idx, inner, tree)
  local args, e = add_args(archive, idx)
  if not args then
    return false, e
  end
  args[#args + 1] = inner
  local ok, e = seven(args, tree, archive)
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
    local args, e = add_args(archive, idx)
    if not args then
      return nil, e
    end
    for _, inner in ipairs(todo) do
      args[#args + 1] = inner
    end
    local ok, e = seven(args, idx.tree, archive)
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
  -- Read-only formats can't take the edit; the copy keeps it until the cache is cleaned.
  if not writable(archive) or #edited_among(idx, inners) == 0 then
    return idx, false
  end
  local saved, e = write_back(archive, inners)
  if not saved then
    ya.notify {
      title = "zipfs",
      content = "Could not save into the archive: " .. tostring(e),
      level = "error",
      timeout = 8,
    }
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

-- Moving a local file to the trash: Yazi's own trash code isn't exposed to plugins, so
-- use whichever command exists. `trash` is built into macOS 14+ and is also trash-cli's
-- name on Linux; `gio trash` comes with GLib (GNOME and most desktops).
local TRASHERS = { { "trash" }, { "gio", "trash" }, { "trash-put" } }

local function to_trash(path)
  for _, t in ipairs(TRASHERS) do
    local args = { table.unpack(t, 2) }
    args[#args + 1] = path
    local out = Command(t[1]):arg(args):stdin(Command.NULL):stdout(Command.NULL):stderr(Command.PIPED):output()
    if out then -- nil: the command doesn't exist, try the next one
      if out.status.success then
        return true
      end
      return false, err("Other", "%s failed: %s", t[1], out.stderr)
    end
  end
  return false, err("NotFound", "No trash command found; install trash-cli, or use D to delete")
end

-- Trash = extract the item, move the copy to the system trash, then delete it from the
-- archive. It stays recoverable from the trash as a normal file/folder.
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

    local _, e = run({ "x", "-y", "-spd", "-sccUTF-8", "-o" .. stage, archive, "--", inner }, archive)
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

    local ok, e = to_trash(copy)
    if not ok then
      return nil, e
    end
    return with_companions({ "d", "-spd", "-sccUTF-8", archive, "--", inner }, idx, inner)
  end)
  fs.remove("dir_all", Url(stage))
  return ok, e
end

-- Ops that change the archive, refused up front for read-only formats.
local WRITES = {
  RemoveFile = true,
  RemoveDir = true,
  RemoveDirAll = true,
  Rename = true,
  CreateDir = true,
  Trash = true,
  SetLen = true,
  Write = true,
}

return {
  mutate = mutate,
  inner_of = inner_of,
  remove = remove,
  rename = rename,
  create_dir = create_dir,
  stage_paths = stage_paths,
  read_meta = read_meta,
  write_meta = write_meta,
  add_args = add_args,
  seven = seven,
  add_from = add_from,
  edited_among = edited_among,
  write_back = write_back,
  settle = settle,
  child_inners = child_inners,
  finish_if_complete = finish_if_complete,
  open_write = open_write,
  set_len = set_len,
  write_chunk = write_chunk,
  TRASHERS = TRASHERS,
  to_trash = to_trash,
  trash = trash,
  WRITES = WRITES,
}
