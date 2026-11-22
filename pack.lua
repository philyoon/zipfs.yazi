--- `plugin zipfs compress` and `plugin zipfs extract`: make and unpack archives. zip and 7z
--- are made with 7zz, compressed tars with the system `tar` (7zz can't write zstd, and tar
--- picks the compression from the name). Loaded only by those two commands.

local state = require(".state")
local targets = state.targets
local core = require(".core")
local FORMATS, format_of, exec, err, source = core.FORMATS, core.format_of, core.exec, core.err, core.source

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

local function ask_new_password()
  local pw, event =
    ya.input { title = "Password for the new archive:", obscure = true, pos = { "top-center", y = 3, w = 50 } }
  if event ~= 1 then
    return nil
  elseif pw == "" then
    return nil, "Not created: the password is empty"
  end
  local again
  again, event = ya.input { title = "Password again:", obscure = true, pos = { "top-center", y = 3, w = 50 } }
  if event ~= 1 then
    return nil
  elseif again ~= pw then
    return nil, "Not created: the passwords differ"
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
    pw, why = ask_new_password()
    if not pw then
      return why and notify(why, "warn")
    end
  end

  if exists(out) then
    local answer, ev =
      ya.input { title = "Overwrite " .. base(out) .. "? (y/N)", pos = { "top-center", y = 3, w = 50 } }
    if ev ~= 1 or answer:lower() ~= "y" then
      return
    end
  end

  -- Build beside the target and rename over it: 7zz would add to an existing archive
  -- instead of replacing it, and a failed run leaves nothing half-written.
  local tmp = string.format("%s/.zipfs-%d%d-%s", dir(out), os.time(), math.random(1e6), base(out))
  local e
  if kind == "tar" then
    local cmd = Command("tar"):arg({ "-caf", tmp }):env("COPYFILE_DISABLE", "1") -- no ._ files on macOS
    for _, p in ipairs(t.paths) do
      cmd:arg { "-C", dir(p), base(p) }
    end
    e = spawn(cmd)
  else
    local args = { "a", "-t" .. kind, "-sccUTF-8" }
    if pw then
      args[#args + 1] = "-p"
      args[#args + 1] = kind == "zip" and "-mem=AES256" or "-mhe=on"
    end
    args[#args + 1] = tmp
    args[#args + 1] = "--"
    for _, p in ipairs(t.paths) do
      args[#args + 1] = p
    end
    e = spawn(Command("7zz"):arg(args), pw)
  end

  if not e then
    local ok, why = os.rename(tmp, out)
    e = not ok and err("Other", "%s", why)
  end
  if e then
    os.remove(tmp)
    return notify("Could not create " .. base(out) .. ": " .. tostring(e), "error")
  end
  notify("Created " .. base(out))
end

-- Unpack `archive` next to itself. Into a temporary folder first: an archive with one
-- top-level item yields just that item, one with more gets a folder named after it.
-- Returns the message to show and its level.
local function unpack(archive)
  local src, e = source(archive) -- a compressed tar is decompressed into the cache first
  if not src then
    return "Could not extract " .. base(archive) .. ": " .. tostring(e), "error"
  end
  local folder = dir(archive)
  local tmp = string.format("%s/.zipfs-extract-%d%d", folder, os.time(), math.random(1e6))
  -- Finder metadata (__MACOSX/, ._name) is left out, as it is hidden when browsing.
  local _
  _, e = exec({ "x", "-y", "-sccUTF-8", "-o" .. tmp, "-xr!__MACOSX", "-xr!._*", src }, archive)
  if e then
    fs.remove("dir_all", Url(tmp))
    return "Could not extract " .. base(archive) .. ": " .. tostring(e), "error"
  end

  local items = fs.read_dir(Url(tmp), { resolve = true }) or {}
  local result
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

-- `plugin zipfs extract`: unpack the selected archives (or the hovered one) next to them.
-- `cmds` brings the password prompt and the lock from cmds.lua.
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
    if not (p and format_of(p)) then
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

return {
  stem = stem,
  kind_of = kind_of,
  compress = compress,
  extract = extract,
}
