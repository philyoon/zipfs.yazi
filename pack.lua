--- `plugin zipfs compress`, `extract`, `save-as` and `find`: make, unpack, convert and
--- search archives. zip and 7z are made with 7zz, tars with the system `tar` (7zz can't
--- write zstd, and tar picks the compression from the name). Loaded only by these commands.

local state = require(".state")
local SCHEME, DOMAIN, targets, get_password, set_password, current_archive =
  state.SCHEME, state.DOMAIN, state.targets, state.get_password, state.set_password, state.current_archive
local core = require(".core")
local FORMATS, format_of, exec, err, source, index =
  core.FORMATS, core.format_of, core.exec, core.err, core.source, core.index

-- Yazi shows three messages at a time and queues the rest, so each command shows one, and
-- success is brief.
local function notify(content, level)
  local timeout = ({ error = 8, warn = 5 })[level] or 2
  ya.notify { title = "zipfs", content = content, level = level or "info", timeout = timeout }
end

local function base(path) return path:match("[^/]+$") end
local function dir(path) return path:match("^(.*)/[^/]+$") or "." end

-- `name` without its archive extension: "a.tar.gz" -> "a", "a.zip" -> "a", "a.b" -> "a".
local function stem(name)
  local lower = name:lower()
  for _, f in ipairs(FORMATS) do
    local s = lower:find(f[1])
    if s and s > 1 then
      return name:sub(1, s - 1)
    end
  end
  return name:match("^(.+)%.[^.]+$") or name
end

local function exists(path) return fs.cha(Url(path)) ~= nil end

-- A name in `folder` that is free: `name`, else "name (1)", "name (2)", ... with the
-- extension kept at the end for files.
local function free_name(folder, name, is_dir)
  if not exists(folder .. "/" .. name) then
    return name
  end
  local s, ext = name, ""
  if not is_dir then
    s, ext = name:match("^(.+)(%..+)$")
    s, ext = s or name, s and ext or ""
  end
  for i = 1, 999 do
    local candidate = string.format("%s (%d)%s", s, i, ext)
    if not exists(folder .. "/" .. candidate) then
      return candidate
    end
  end
end

-- Run a command, writing `pw` to its stdin when given. Returns nil or an error.
local function spawn(cmd, pw)
  cmd:stdout(Command.PIPED):stderr(Command.PIPED)
  local out, e
  if pw then
    local child
    child, e = cmd:stdin(Command.PIPED):spawn()
    if child then
      child:write_all(string.rep(pw .. "\n", 3)) -- 7zz asks twice when making an encrypted 7z
      child:flush()
      out, e = child:wait_with_output()
    end
  else
    out, e = cmd:stdin(Command.NULL):output()
  end
  if not out then
    return err("NotFound", "%s", e)
  elseif not out.status.success then
    return err("Other", "%s", (out.stderr ~= "" and out.stderr or out.stdout):gsub("%s+$", ""))
  end
end

local TARS =
  { "%.tar$", "%.tar%.gz$", "%.tgz$", "%.tar%.bz2$", "%.tbz2?$", "%.tar%.xz$", "%.txz$", "%.tar%.zst$", "%.tzst$" }

-- "zip", "7z", "tar" (any tar, compressed or not), or nil.
local function kind_of(name)
  local lower = name:lower()
  for _, p in ipairs(TARS) do
    if lower:find(p) then
      return "tar"
    end
  end
  local f = format_of(lower)
  return f and f.type
end

-- A file compressed on its own, not a tar: "notes.txt.gz". 7zz unpacks these to the one
-- file inside. (Compressed tars match FORMATS first.)
local SINGLES = { "%.gz$", "%.bz2$", "%.xz$", "%.zst$", "%.lzma$", "%.z$" }

local function is_single(name)
  local lower = name:lower()
  if format_of(lower) then
    return false
  end
  for _, p in ipairs(SINGLES) do
    if lower:find(p) then
      return true
    end
  end
  return false
end

-- Finder litter left out of the folders you compress. A file with one of these names that
-- you selected yourself still goes in, so its pattern is dropped then.
local JUNK = { ".DS_Store", "._*", "Icon\r" }

local function junk_excludes(paths)
  local out = {}
  for _, pat in ipairs(JUNK) do
    local picked = false
    for _, p in ipairs(paths) do
      local b = base(p)
      picked = picked or b == pat or (pat == "._*" and b:sub(1, 2) == "._")
    end
    if not picked then
      out[#out + 1] = pat
    end
  end
  return out
end

-- Pack `paths` into `out` (a temporary name; the caller renames it into place). `pw`
-- encrypts a zip (AES-256) or 7z (names too). Returns nil or an error.
local function build(kind, out, paths, pw, excludes)
  if kind == "tar" then
    local cmd = Command("tar"):arg({ "-caf", out }):env("COPYFILE_DISABLE", "1") -- no ._ files on macOS
    for _, x in ipairs(excludes) do
      cmd:arg { "--exclude", x } -- GNU tar wants these before the files
    end
    for _, p in ipairs(paths) do
      cmd:arg { "-C", dir(p), base(p) }
    end
    return spawn(cmd)
  end
  local args = { "a", "-t" .. kind, "-sccUTF-8" }
  if pw then
    args[#args + 1] = "-p"
    args[#args + 1] = kind == "zip" and "-mem=AES256" or "-mhe=on"
  end
  for _, x in ipairs(excludes) do
    args[#args + 1] = "-xr!" .. x
  end
  args[#args + 1] = out
  args[#args + 1] = "--"
  for _, p in ipairs(paths) do
    args[#args + 1] = p
  end
  return spawn(Command("7zz"):arg(args), pw)
end

-- Build beside `out` and rename over it: 7zz would add to an existing archive instead of
-- replacing it, and a failed run leaves nothing half-written.
local function build_into(kind, out, paths, pw, excludes)
  local tmp = string.format("%s/.zipfs-%d%d-%s", dir(out), os.time(), math.random(1e6), base(out))
  local e = build(kind, tmp, paths, pw, excludes)
  if not e then
    local ok, why = os.rename(tmp, out)
    e = not ok and err("Other", "%s", why) or nil
  end
  if e then
    os.remove(tmp)
  end
  return e
end

local function confirm(question)
  local answer, event = ya.input { title = question .. " (y/N)", pos = { "top-center", y = 3, w = 50 } }
  return event == 1 and answer:lower() == "y"
end

-- Ask for a new password, twice. With `optional`, an empty one means none (returns "").
local function ask_new_password(verb, optional)
  local pw, event = ya.input {
    title = "Password for the new archive" .. (optional and " (empty for none):" or ":"),
    obscure = true,
    pos = { "top-center", y = 3, w = 50 },
  }
  if event ~= 1 then
    return nil
  elseif pw == "" then
    if optional then
      return ""
    end
    return nil, "Not " .. verb .. ": the password is empty"
  end
  local again
  again, event = ya.input { title = "Password again:", obscure = true, pos = { "top-center", y = 3, w = 50 } }
  if event ~= 1 then
    return nil
  elseif again ~= pw then
    return nil, "Not " .. verb .. ": the passwords differ"
  end
  return pw
end

-- `plugin zipfs compress [ext] [--encrypt]`: pack the selected files (or the hovered one)
-- into a new archive next to them. The name you type picks the format.
local function compress(job)
  ya.emit("escape", { visual = true })
  local t = targets()
  if not t.cwd or #t.paths == 0 then
    return notify("Compress works on files in a plain folder, not inside an archive", "warn")
  end
  for _, p in ipairs(t.paths) do
    if not p then
      return notify("Compress works on files in a plain folder, not inside an archive", "warn")
    end
  end

  local default = (#t.paths == 1 and base(t.paths[1]) or t.name) .. "." .. (job.args[2] or "zip")
  local name, event = ya.input { title = "Create archive:", value = default, pos = { "top-center", y = 3, w = 50 } }
  if event ~= 1 or name == "" then
    return
  end
  local out = name:sub(1, 1) == "/" and name or t.cwd .. "/" .. name
  local kind = kind_of(base(out))
  if not kind then
    return notify("Not created: end the name in .zip, .7z, .tar, .tar.gz, .tar.bz2, .tar.xz or .tar.zst", "warn")
  end

  local pw
  if job.args.encrypt then
    if kind == "tar" then
      return notify("Not created: only zip and 7z can be encrypted", "warn")
    end
    local why
    pw, why = ask_new_password("created")
    if not pw then
      return why and notify(why, "warn")
    end
  end

  if exists(out) and not confirm("Overwrite " .. base(out) .. "?") then
    return
  end
  local e = build_into(kind, out, t.paths, pw, junk_excludes(t.paths))
  if e then
    return notify("Could not create " .. base(out) .. ": " .. tostring(e), "error")
  end
  notify("Created " .. base(out))
end

-- Extract all of `archive` into a new temporary folder beside `near`. `meta` keeps Finder
-- metadata (__MACOSX/, ._name), which is otherwise left out as it is hidden when browsing.
-- Returns the folder and its items, or nil and an error.
local function unpack_to(archive, near, meta)
  local src, e = source(archive) -- a compressed tar is decompressed into the cache first
  if not src then
    return nil, e
  end
  local tmp = string.format("%s/.zipfs-extract-%d%d", dir(near), os.time(), math.random(1e6))
  local args = { "x", "-y", "-sccUTF-8", "-o" .. tmp }
  if not meta then
    args[#args + 1] = "-xr!__MACOSX"
    args[#args + 1] = "-xr!._*"
  end
  args[#args + 1] = src
  local _
  _, e = exec(args, archive)
  if e then
    fs.remove("dir_all", Url(tmp))
    return nil, e
  end
  return tmp, fs.read_dir(Url(tmp), { resolve = true }) or {}
end

-- Unpack `archive` next to itself. An archive with one top-level item yields just that
-- item, one with more gets a folder named after it. Returns the message and its level.
local function unpack(archive)
  local tmp, items = unpack_to(archive, archive, false)
  if not tmp then
    return "Could not extract " .. base(archive) .. ": " .. tostring(items), "error"
  end
  local folder, result = dir(archive), nil
  if #items == 0 then
    fs.remove("dir", Url(tmp))
    return base(archive) .. " is empty", "warn"
  elseif #items == 1 then
    result = free_name(folder, items[1].name, items[1].cha.is_dir)
    os.rename(tostring(items[1].url), folder .. "/" .. result)
    fs.remove("dir", Url(tmp))
  else
    result = free_name(folder, stem(base(archive)), true)
    os.rename(tmp, folder .. "/" .. result)
  end
  return "Extracted " .. base(archive) .. " to " .. result
end

-- `plugin zipfs extract`: unpack the selected archives (or the hovered one) next to them,
-- and files compressed on their own (.gz, .xz, ...). `cmds` brings the password prompt and
-- the lock from cmds.lua.
local function extract(_, cmds)
  ya.emit("escape", { visual = true })
  local lines, worst, skipped = {}, nil, 0
  local function report(msg, level)
    lines[#lines + 1] = msg
    if level == "error" or (level == "warn" and worst ~= "error") then
      worst = level
    end
  end
  for _, p in ipairs(targets().paths) do
    if p and is_single(p) then
      report(unpack(p))
    elseif not (p and format_of(p)) then
      skipped = skipped + 1
    elseif not cmds.needs_password(p) then
      report(unpack(p))
    else
      local ok, cancelled = cmds.ask_password(p)
      if ok then
        report(unpack(p))
        cmds.lock(p) -- asked only for this: don't keep the password or a decrypted listing
      elseif cancelled then
        report("Not extracted: " .. base(p) .. " needs the password", "warn")
      end
    end
  end
  if skipped > 0 then
    report(
      string.format("Skipped %d item%s: not an archive, or inside one", skipped, skipped > 1 and "s" or ""),
      "warn"
    )
  end
  if #lines > 0 then
    notify(table.concat(lines, "\n"), worst)
  end
end

-- `plugin zipfs save-as`: write the hovered archive, or the one you are in, into a new
-- one: another format, another password, or none. Everything goes along, Finder metadata
-- included. `cmds` brings the target, the password prompt and the lock from cmds.lua.
local function save_as(_, cmds)
  local archive = cmds.test_target()
  if not archive then
    return notify("Hover an archive or enter one first", "warn")
  end
  local asked = false -- unlocked only for this, so locked again at the end
  if cmds.needs_password(archive) then
    local ok, cancelled = cmds.ask_password(archive)
    if not ok then
      return cancelled and notify("Not saved: " .. base(archive) .. " needs the password", "warn")
    end
    asked = true
  end
  local function finish(msg, level)
    if asked then
      cmds.lock(archive)
    end
    if msg then
      notify(msg, level)
    end
  end

  local name = stem(base(archive))
  local default = name .. ".zip"
  if dir(archive) .. "/" .. default == archive then
    default = name .. "-copy.zip"
  end
  local input, event = ya.input { title = "Save as:", value = default, pos = { "top-center", y = 3, w = 50 } }
  if event ~= 1 or input == "" then
    return finish()
  end
  local out = input:sub(1, 1) == "/" and input or dir(archive) .. "/" .. input
  local kind = kind_of(base(out))
  if not kind then
    return finish("Not saved: end the name in .zip, .7z, .tar, .tar.gz, .tar.bz2, .tar.xz or .tar.zst", "warn")
  end

  local was_encrypted = get_password(archive) ~= nil
  local pw = ""
  if kind ~= "tar" then
    local why
    pw, why = ask_new_password("saved", true)
    if not pw then
      return finish(why, "warn")
    end
  end
  if pw == "" and was_encrypted and not confirm("Save without a password?") then
    return finish()
  end
  if exists(out) and not confirm("Overwrite " .. base(out) .. "?") then
    return finish()
  end

  -- Edits not yet saved into the archive go along.
  local idx = index(archive)
  if idx and core.writable(archive) then
    require(".edit").settle(archive, idx, nil)
  end
  local tmp, items = unpack_to(archive, out, true)
  if not tmp then
    return finish("Could not save " .. base(out) .. ": " .. tostring(items), "error")
  elseif #items == 0 then
    fs.remove("dir", Url(tmp))
    return finish(base(archive) .. " is empty", "warn")
  end
  local paths = {}
  for i, it in ipairs(items) do
    paths[i] = tostring(it.url)
  end
  local e = build_into(kind, out, paths, pw ~= "" and pw or nil, {})
  fs.remove("dir_all", Url(tmp))
  if e then
    return finish("Could not save " .. base(out) .. ": " .. tostring(e), "error")
  end
  if out == archive and not asked then
    set_password(archive, pw ~= "" and pw or nil) -- you are inside: keep it browsable
  end
  finish(out == archive and "Saved " .. base(out) or "Saved " .. base(archive) .. " as " .. base(out))
end

-- `plugin zipfs find`: pick any entry of the archive you are in with fzf, and go to it.
local function find()
  local archive = current_archive()
  if not archive then
    return notify("Enter an archive first", "warn")
  end
  local idx, e = index(archive)
  if not idx then
    return notify(tostring(e), "error")
  end
  local list = {}
  for path, info in pairs(idx.entries) do
    if path ~= "" then
      list[#list + 1] = info.dir and path .. "/" or path
    end
  end
  table.sort(list)

  local permit = ui.hide()
  local child, why =
    Command("fzf"):arg({ "--prompt", base(archive) .. "> " }):stdin(Command.PIPED):stdout(Command.PIPED):spawn()
  local out
  if child then
    child:write_all(table.concat(list, "\n") .. "\n")
    child:flush()
    out = child:wait_with_output()
  end
  permit:drop()
  if not child then
    return notify("find needs fzf in PATH: " .. tostring(why), "error")
  end
  local pick = out and out.stdout:gsub("%s+$", ""):gsub("/$", "")
  if not pick or pick == "" or not idx.entries[pick] then
    return -- cancelled
  end
  local url = Url(string.format("%s://%s/%s", SCHEME, DOMAIN, archive))
  for part in pick:gmatch("[^/]+") do
    url = url:join(part)
  end
  ya.emit("reveal", { url })
end

return {
  stem = stem,
  kind_of = kind_of,
  is_single = is_single,
  junk_excludes = junk_excludes,
  compress = compress,
  extract = extract,
  save_as = save_as,
  find = find,
}
