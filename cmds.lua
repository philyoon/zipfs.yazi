--- What only `plugin zipfs` runs: entering archives, passwords, locking, the cache
--- cleanup, the integrity check. Loaded only then, so VFS calls don't parse it.

local state = require(".state")
local SCHEME, DOMAIN, get_password, set_password, unlocked =
  state.SCHEME, state.DOMAIN, state.get_password, state.set_password, state.unlocked
local is_open, forget_passwords, hovered, current_archive, cwd_url =
  state.is_open, state.forget_passwords, state.hovered, state.current_archive, state.cwd_url
local core = require(".core")
local format_of, writable, exec, run, read_file = core.format_of, core.writable, core.exec, core.run, core.read_file
local write_atomic, cache_root, archive_prefix, archive_dir, locate =
  core.write_atomic, core.cache_root, core.archive_prefix, core.archive_dir, core.locate
local index, extract = core.index, core.extract
local edit = require(".edit")
local edited_among, settle = edit.edited_among, edit.settle

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
  return e.name:find("%.lock$") or e.name:find("^stage%-") or e.name:find("%.x%d+$") or e.name == "writes"
end

-- Before an archive's extracted copies are deleted, save the edited ones into the zip.
-- False means some could not be saved, so the copies must stay.
local function save_tree(prefix)
  local archive = read_file(string.format("%s/%stree.src", cache_root(), prefix))
  if not archive or not fs.cha(Url(archive)) or not writable(archive) then
    return true -- the archive is gone, or can't be written; nothing to save into
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

-- Yazi's pid, which spawned this command's shell. Marks whose decrypted copies these are.
local function yazi_pid()
  local out = Command("sh"):arg({ "-c", "echo $PPID" }):stdin(Command.NULL):stdout(Command.PIPED):output()
  return out and out.stdout:match("%d+")
end

local function alive(pid)
  local out = pid and Command("kill"):arg({ "-0", pid }):stdin(Command.NULL):stderr(Command.NULL):output()
  return out ~= nil and out.status.success
end

local function owned_by(archive) return string.format("%s/%spid", cache_root(), archive_prefix(archive)) end

-- Delete an archive's cache entries. With `keep_edits`, the tree (holding edits that could
-- not be saved) stays, with the listing and tree.src that saving it later needs.
local function purge(prefix, keep_edits)
  for _, e in ipairs(cache_entries()) do
    local rest = e.name:sub(1, #prefix) == prefix and e.name:sub(#prefix + 1)
    local needed = rest == "tree" or rest == "tree.src" or (rest and rest:find("%.list$"))
    if rest and not busy(e) and not (keep_edits and needed) then
      fs.remove(e.cha.is_dir and "dir_all" or "file", e.url)
    end
  end
end

-- Leaving an encrypted archive: save edits, forget the password, then delete its decrypted
-- copies and listing. Forgetting first means a preview racing with this can't decrypt a
-- new copy. `force` skips the "still open in a tab" check (quitting).
local function lock(archive, force)
  if not force and is_open(archive) then
    return set_password(archive, get_password(archive)) -- came back in meanwhile
  end
  local prefix = archive_prefix(archive)
  local saved = save_tree(prefix)
  set_password(archive, nil)
  purge(prefix, not saved)
  if not saved then
    ya.notify {
      title = "zipfs",
      content = "Edits in "
        .. archive:match("[^/]+$")
        .. " could not be saved; their decrypted copies stay in the cache",
      level = "warn",
      timeout = 8,
    }
  end
end

-- Decrypted copies left by a Yazi that is gone (crashed, or its terminal closed).
-- Edited copies are kept: entering that archive again saves them.
local function sweep_orphans()
  for _, e in ipairs(cache_entries()) do
    local prefix = e.name:match("^(%x+%-)pid$")
    if prefix and not alive((read_file(tostring(e.url)) or ""):match("%d+")) then
      purge(prefix, not save_tree(prefix)) -- without the password, edits can't be saved
    end
  end
end

-- `plugin zipfs quit`: lock every encrypted archive, then quit.
local function quit(job)
  for _, archive in ipairs(unlocked()) do
    lock(archive, true)
  end
  ya.emit("quit", { no_cwd_file = job.args.no_cwd_file or nil })
end

local function clean()
  local root = cache_root()
  -- Yazi doesn't re-detect MIME types after a clean, so previews in the zip you're in would
  -- point at deleted copies. Keep that one.
  local here = current_archive()
  local keep = here and archive_prefix(here)
  forget_passwords(here) -- along with the decrypted copies
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
    msg = msg .. " Kept the archive you're in."
  end
  if skipped > 0 then
    msg = msg .. " An edit is in progress; its files were kept."
  end
  if unsaved > 0 then
    msg = msg .. " Edited files that could not be saved into their archive were kept."
  end
  ya.notify { title = "zipfs cache", content = msg, timeout = 4, level = unsaved > 0 and "warn" or "info" }
end

-- The archive `plugin zipfs test` checks: the hovered one, or the one you are inside.
local function test_target()
  local h = hovered()
  if h and h.is_regular and format_of(h.url) then
    return h.url
  end
  local path = cwd_url():match("^" .. SCHEME .. "://" .. DOMAIN .. "[:%d]*/(/.*)$")
  while path and path ~= "" do
    if format_of(path) then
      local cha = fs.cha(Url(path))
      if cha and not cha.is_dir then
        return path
      end
    end
    path = path:match("^(.*)/[^/]*$")
  end
end

-- `7zz t`: decompress everything and compare the stored checksums.
local function test()
  local archive = test_target()
  if not archive then
    return ya.notify { title = "zipfs", content = "Hover an archive or enter one first", level = "warn", timeout = 4 }
  end
  local name = archive:match("[^/]+$")
  ya.notify { title = "zipfs", content = "Testing " .. name .. "...", timeout = 2 }
  local _, e = exec({ "t", "-bd", "-sccUTF-8", archive }, archive)
  if not e then
    return ya.notify { title = "zipfs", content = name .. ": no errors", timeout = 4 }
  end
  local msg, lines = tostring(e), {}
  if not msg:find("^7zz failed") then
    return ya.notify { title = "zipfs", content = msg, level = "error", timeout = 5 }
  end
  for line in msg:gmatch("[^\n]+") do
    if #lines < 5 and line:find("[Ee][Rr][Rr][Oo][Rr]") and not line:find("^7zz failed") then
      lines[#lines + 1] = line
    end
  end
  if #lines == 0 then
    lines[1] = msg
  end
  ya.notify {
    title = "zipfs: " .. name .. " is damaged",
    content = table.concat(lines, "\n"),
    level = "error",
    timeout = 10,
  }
end

local function password_error(e) return e and (tostring(e):find("encrypted") or tostring(e):find("Wrong password")) end

-- Does `archive` need a password zipfs doesn't have yet? Returns true, or false plus the
-- listing (nil when even the names are encrypted and no password is known).
local function needs_password(archive)
  local idx, e = index(archive)
  if not idx then
    return password_error(e) ~= nil, nil
  end
  return idx.encrypted and not get_password(archive), idx
end

-- A password is right if the listing opens with it and the smallest encrypted file passes
-- `7zz t`.
local function check_password(archive)
  local idx, e = index(archive)
  if not idx then
    return false, e
  end
  local pick
  for _, info in pairs(idx.entries) do
    if info.encrypted and not info.dir and (not pick or info.len < pick.len) then
      pick = info
    end
  end
  if not pick then
    return true
  end
  local _, e = run({ "t", "-sccUTF-8", archive, "--", pick.raw }, archive)
  return e == nil, e
end

-- Ask for `archive`'s password (three tries) and keep it in memory. Returns true when a
-- correct one was entered, else false and whether the prompt was cancelled (other failures
-- have already been reported).
local function ask_password(archive)
  local name = archive:match("[^/]+$")
  for try = 1, 3 do
    local pw, event = ya.input {
      title = (try > 1 and "Wrong password. " or "") .. "Password for " .. name .. ":",
      obscure = true,
      pos = { "top-center", y = 3, w = 60 },
    }
    if event ~= 1 then
      return false, true
    end
    set_password(archive, pw)
    local ok, e = check_password(archive)
    if ok then
      write_atomic(owned_by(archive), yazi_pid() or "")
      return true
    end
    set_password(archive, nil)
    if not password_error(e) then
      ya.notify { title = "zipfs", content = tostring(e), level = "error", timeout = 5 }
      return false
    end
  end
  ya.notify { title = "zipfs", content = "Wrong password for " .. name, level = "error", timeout = 5 }
  return false
end

-- `plugin zipfs clean` empties the cache. `plugin zipfs test` checks an archive. Otherwise, like smart-enter: zip -> browse
-- inside, directory -> enter, other file -> open.
local function entry(job)
  if job.args[1] == "clean" then
    return clean()
  elseif job.args[1] == "test" then
    return test()
  elseif job.args[1] == "lock" and job.args[2] then
    return lock(job.args[2])
  elseif job.args[1] == "quit" then
    return quit(job)
  end

  local h = hovered()

  if h and h.is_regular and format_of(h.url) then
    touch(h.url)
    sweep_orphans()
    -- Without the right password, stay outside: a zip's names are readable, but showing
    -- them would look like the password was accepted while no file opens.
    if needs_password(h.url) and not ask_password(h.url) then
      return
    end
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
    local url = Url(h.url)
    local _, e = extract(url)
    if password_error(e) then
      local archive = locate(url)
      local ok, cancelled = false, false
      if archive then
        ok, cancelled = ask_password(archive)
      end
      if not ok then
        if cancelled then
          ya.notify {
            title = "zipfs",
            content = "Not opened: " .. h.url:match("[^/]+$") .. " is encrypted and needs the password",
            level = "warn",
            timeout = 5,
          }
        end
        return
      end
      _, e = extract(url)
    end
    if e then
      return ya.notify { title = "zipfs", content = tostring(e), level = "error", timeout = 5 }
    end
  end
  ya.emit(h and h.is_dir and "enter" or "open", { hovered = true })
end

return {
  CACHE_MAX_AGE = CACHE_MAX_AGE,
  cache_entries = cache_entries,
  busy = busy,
  save_tree = save_tree,
  delete_entries = delete_entries,
  prune_old = prune_old,
  touch = touch,
  yazi_pid = yazi_pid,
  alive = alive,
  owned_by = owned_by,
  purge = purge,
  lock = lock,
  sweep_orphans = sweep_orphans,
  quit = quit,
  clean = clean,
  test_target = test_target,
  test = test,
  password_error = password_error,
  needs_password = needs_password,
  check_password = check_password,
  ask_password = ask_password,
  entry = entry,
}
