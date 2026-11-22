--- Shared state in Yazi's main Lua state: passwords, and what the tabs show. Every
--- ya.sync lives here, because each file gets its own plugin state.

local SCHEME, DOMAIN = "archive", "zip"

-- Passwords live in the plugin's state in Yazi's main Lua state, which outlives the fresh
-- state each VFS call gets. They are never written to disk and go when Yazi quits.
local get_password = ya.sync(function(st, archive) return st.passwords and st.passwords[archive] end)

-- The archives open in some tab, as { [archive path] = true }.
local function open_archives()
  local open = {}
  for i = 1, #cx.tabs do
    local cwd = cx.tabs[i].current.cwd
    if cwd.spec.scheme == SCHEME and cwd.base then
      open[(tostring(cwd.base.path):gsub("/+$", ""))] = true
    end
  end
  return open
end

local set_password = ya.sync(function(st, archive, pw)
  st.passwords = st.passwords or {}
  st.passwords[archive] = pw
  st.locking = st.locking or {}
  st.locking[archive] = nil
  if pw and not st.watching then
    -- Once no tab is inside an archive with a password, lock it: `plugin zipfs lock`
    -- saves edits, deletes the decrypted copies and forgets the password. That is too
    -- slow for this callback, so it runs as a plugin call of its own.
    st.watching = true
    ps.sub("cd", function()
      local open = open_archives()
      for a in pairs(st.passwords) do
        if not open[a] and not st.locking[a] then
          st.locking[a] = true
          ya.emit("plugin", { "zipfs", "lock " .. ya.quote(a) })
        end
      end
    end)
  end
end)

local unlocked = ya.sync(function(st)
  local out = {}
  for a in pairs(st.passwords or {}) do
    out[#out + 1] = a
  end
  return out
end)

local is_open = ya.sync(function(_, archive) return open_archives()[archive] == true end)

local forget_passwords = ya.sync(function(st, keep)
  local pw = keep and st.passwords and st.passwords[keep]
  st.passwords = {}
  if pw then
    st.passwords[keep] = pw
  end
end)

local hovered = ya.sync(function()
  local f = cx.active.current.hovered
  return f
    and {
      url = tostring(f.url),
      is_regular = f.url.spec.is_regular,
      in_zip = f.url.spec.scheme == SCHEME,
      is_dir = f.cha.is_dir,
    }
end)

-- The archive the active tab is inside, if any.
local current_archive = ya.sync(function()
  local cwd = cx.active.current.cwd
  if cwd.spec.scheme == SCHEME and cwd.base then
    return (tostring(cwd.base.path):gsub("/+$", ""))
  end
end)

local cwd_url = ya.sync(function() return tostring(cx.active.current.cwd) end)

return {
  SCHEME = SCHEME,
  DOMAIN = DOMAIN,
  get_password = get_password,
  open_archives = open_archives,
  set_password = set_password,
  unlocked = unlocked,
  is_open = is_open,
  forget_passwords = forget_passwords,
  hovered = hovered,
  current_archive = current_archive,
  cwd_url = cwd_url,
}
