-- Unit tests for the pure parts of core.lua (listing parser, format table).
-- Run from anywhere: lua tests/unit.lua   (Lua 5.4+, no other dependencies)
--
-- The plugin expects Yazi's globals. Only `ya.sync` runs at load time, so that is all the
-- stub needs; everything else is touched only inside functions these tests don't call.
-- Yazi resolves `require(".name")` to name.lua beside the plugin; so does this shim.

ya = { sync = function(f) return f end }

local here = arg[0]:match("^(.*)/[^/]+$") or "."
local plain_require, loaded = require, {}
function require(name)
  if name:sub(1, 1) ~= "." then
    return plain_require(name)
  end
  loaded[name] = loaded[name] or dofile(here .. "/../" .. name:sub(2) .. ".lua")
  return loaded[name]
end
local T = require(".core")

local failed, passed = 0, 0

local function check(name, cond, detail)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function eq(name, got, want)
  check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

local function sorted(t)
  local out = {}
  for _, v in ipairs(t or {}) do
    out[#out + 1] = v
  end
  table.sort(out)
  return table.concat(out, ",")
end

-- Build `7zz l -slt -ba` style output from a list of field tables.
local function listing(blocks)
  local out = {}
  for _, b in ipairs(blocks) do
    local lines = {}
    for _, k in ipairs { "ZipfsLocked", "Path", "Folder", "Size", "Modified", "Attributes", "Encrypted", "Method" } do
      if b[k] then
        lines[#lines + 1] = k .. " = " .. b[k]
      end
    end
    out[#out + 1] = table.concat(lines, "\n")
  end
  return table.concat(out, "\n\n") .. "\n"
end

-- format_of / writable ------------------------------------------------------------------

for name, want in pairs {
  ["a.zip"] = "zip",
  ["A.ZIP"] = "zip",
  ["lib.jar"] = "zip",
  ["b.7z"] = "7z",
  ["c.rar"] = "ro",
  ["d.tar"] = "ro",
  ["e.tar.gz"] = "tar",
  ["f.tgz"] = "tar",
  ["g.tar.bz2"] = "tar",
  ["h.tbz"] = "tar",
  ["i.tbz2"] = "tar",
  ["j.tar.xz"] = "tar",
  ["k.txz"] = "tar",
  ["l.tar.zst"] = "tar",
  ["m.tzst"] = "tar",
  ["book.epub"] = "zip",
  ["app.apk"] = "zip",
  ["pkg.whl"] = "zip",
  ["comic.cbz"] = "zip",
  ["comic.cb7"] = "7z",
  ["comic.cbr"] = "ro",
  ["disc.iso"] = "ro",
  ["setup.cab"] = "ro",
  ["image.dmg"] = nil, -- 7zz lists folders in it as files
  ["n.gz"] = nil, -- a plain gzip file is not an archive of files
  ["o.txt"] = nil,
  ["zip"] = nil,
} do
  local f = T.format_of("/x/" .. name)
  local got = f and (f.tar and "tar" or f.type or "ro") or nil
  eq("format_of " .. name, got, want)
end

check("zip is writable", T.writable("/x/a.zip"))
check("7z is writable", T.writable("/x/a.7z"))
check("rar is read-only", not T.writable("/x/a.rar"))
check("tar.gz is read-only", not T.writable("/x/a.tar.gz"))

-- parse_time / parse_mode ---------------------------------------------------------------

eq(
  "parse_time plain",
  T.parse_time("2026-01-02 03:04:05"),
  os.time { year = 2026, month = 1, day = 2, hour = 3, min = 4, sec = 5 }
)
eq("parse_time 7z fractions", T.parse_time("2026-01-02 03:04:05.1234567"), T.parse_time("2026-01-02 03:04:05"))
eq("parse_time empty", T.parse_time(""), nil)

eq("parse_mode zip file", T.parse_mode("-rw-r--r--", false), tonumber("100644", 8))
eq("parse_mode 7z dir", T.parse_mode("D drwxr-x---", true), tonumber("40750", 8))
eq("parse_mode exec", T.parse_mode("A -rwxr-xr-x", false), tonumber("100755", 8))
eq("parse_mode windows zip", T.parse_mode("A", false), tonumber("100644", 8))
eq("parse_mode windows dir", T.parse_mode("D", true), tonumber("40755", 8))

-- parse_listing: zip ----------------------------------------------------------------------

do
  local idx = T.parse_listing(listing {
    { Path = "docs", Folder = "+", Size = "0", Modified = "2026-01-01 00:00:00", Attributes = "D drwxr-xr-x" },
    { Path = "docs/a.txt", Folder = "-", Size = "12", Modified = "2026-01-01 00:00:02", Attributes = "-rw-r--r--" },
    { Path = "한글.txt", Folder = "-", Size = "3", Attributes = "-rw-r--r--" },
  })
  eq("zip root children", sorted(idx.children[""]), sorted { "docs", "한글.txt" })
  check("zip docs is dir", idx.entries.docs.dir)
  eq("zip file len", idx.entries["docs/a.txt"].len, 12)
  eq("zip korean len", idx.entries["한글.txt"].len, 3)
  eq("zip raw path kept", idx.entries["docs/a.txt"].raw, "docs/a.txt")
end

-- parse_listing: zip without directory entries (zip -D) ---------------------------------

do
  local idx = T.parse_listing(listing {
    { Path = "a/b/c.txt", Folder = "-", Size = "1" },
  })
  check("implicit dir a", idx.entries.a and idx.entries.a.dir)
  check("implicit dir a/b", idx.entries["a/b"] and idx.entries["a/b"].dir)
  eq("implicit children", sorted(idx.children["a/b"]), "c.txt")
  eq("implicit root", sorted(idx.children[""]), "a")
end

-- parse_listing: 7z (no Folder field; directories marked by "D" attributes) -------------

do
  local idx = T.parse_listing(listing {
    { Path = "d", Size = "0", Attributes = "D drwxr-xr-x" },
    { Path = "b.txt", Size = "7", Attributes = "A -rw-r--r--" },
    { Path = "d/a.txt", Size = "3", Attributes = "A -rw-r--r--" },
  })
  check("7z d is dir", idx.entries.d.dir)
  check("7z b.txt is file", not idx.entries["b.txt"].dir)
  eq("7z d children", sorted(idx.children.d), "a.txt")
end

-- parse_listing: tar with "./" paths --------------------------------------------------

do
  local idx = T.parse_listing(listing {
    { Path = ".", Folder = "+" },
    { Path = "./b.txt", Folder = "-", Size = "7" },
    { Path = "./d", Folder = "+" },
    { Path = "./d/a.txt", Folder = "-", Size = "3" },
  })
  eq("tar root children", sorted(idx.children[""]), sorted { "b.txt", "d" })
  check("tar no '.' entry", idx.entries["."] == nil)
  eq("tar raw keeps ./", idx.entries["d/a.txt"].raw, "./d/a.txt")
  eq("tar d children", sorted(idx.children.d), "a.txt")
end

-- parse_listing: hostile paths are dropped ---------------------------------------------

do
  local idx = T.parse_listing(listing {
    { Path = "../evil.txt", Folder = "-", Size = "1" },
    { Path = "ok/../../evil2.txt", Folder = "-", Size = "1" },
    { Path = "..", Folder = "+" },
    { Path = "/abs.txt", Folder = "-", Size = "1" },
    { Path = "fine.txt", Folder = "-", Size = "1" },
  })
  check("drops ../", idx.entries["../evil.txt"] == nil)
  check("drops a/../..", idx.entries["ok/../../evil2.txt"] == nil)
  check("drops ..", idx.entries[".."] == nil)
  check("absolute made relative", idx.entries["abs.txt"] ~= nil)
  check("keeps normal", idx.entries["fine.txt"] ~= nil)
end

-- parse_listing + companions: macOS metadata ------------------------------------------

do
  local idx = T.parse_listing(listing {
    { Path = "photo.txt", Folder = "-", Size = "6" },
    { Path = "._photo.txt", Folder = "-", Size = "4" },
    { Path = "d2", Folder = "+" },
    { Path = "d2/x.txt", Folder = "-", Size = "2" },
    { Path = "__MACOSX", Folder = "+" },
    { Path = "__MACOSX/._photo.txt", Folder = "-", Size = "4" },
    { Path = "__MACOSX/._d2", Folder = "-", Size = "4" },
    { Path = "__MACOSX/d2", Folder = "+" },
    { Path = "__MACOSX/d2/._x.txt", Folder = "-", Size = "4" },
  })
  eq("mac root children", sorted(idx.children[""]), sorted { "d2", "photo.txt" })
  check("no __MACOSX entry", idx.entries.__MACOSX == nil)
  check("no ._photo entry", idx.entries["._photo.txt"] == nil)
  check("__MACOSX remembered", idx.hidden["__MACOSX/d2/._x.txt"] ~= nil)

  local function names(list, i)
    local out = {}
    for _, c in ipairs(list) do
      out[#out + 1] = c[i]
    end
    return table.concat(out, ",")
  end
  local c = T.companions(idx, "photo.txt", "pic.txt")
  eq("file companions", names(c, 1), "._photo.txt,__MACOSX/._photo.txt")
  eq("file companions renamed", names(c, 2), "._pic.txt,__MACOSX/._pic.txt")
  c = T.companions(idx, "d2", "e")
  eq("folder companions (subtree once)", names(c, 1), "__MACOSX/._d2,__MACOSX/d2")
  eq("folder companions renamed", names(c, 2), "__MACOSX/._e,__MACOSX/e")
  eq("nested file companions", names(T.companions(idx, "d2/x.txt"), 1), "__MACOSX/d2/._x.txt")
  eq("none for unrelated", #T.companions(idx, "nothing"), 0)
end

-- parse_listing: encryption flags ------------------------------------------------------

do
  local idx = T.parse_listing(listing {
    { Path = "a.txt", Folder = "-", Size = "1", Encrypted = "+", Method = "AES-256 Deflate" },
    { Path = "b.txt", Folder = "-", Size = "1", Encrypted = "-", Method = "Deflate" },
  })
  check("zip encrypted", idx.encrypted)
  check("zip aes", idx.aes)
  check("zip names not locked", not idx.locked)
  check("entry encrypted", idx.entries["a.txt"].encrypted)
  check("entry plain", not idx.entries["b.txt"].encrypted)

  idx = T.parse_listing(listing {
    { Path = "a.txt", Folder = "-", Size = "1", Encrypted = "+", Method = "ZipCrypto Store" },
  })
  check("zipcrypto is not aes", idx.encrypted and not idx.aes)

  idx = T.parse_listing(listing {
    { ZipfsLocked = "+" },
    { Path = "a.txt", Size = "1", Attributes = "A -rw-r--r--", Encrypted = "+", Method = "LZMA2:12 7zAES:19" },
  })
  check("7z names locked", idx.locked)
  eq("locked marker adds no entry", sorted(idx.children[""]), "a.txt")

  idx = T.parse_listing(listing { { Path = "a.txt", Folder = "-", Size = "1" } })
  check("plain zip", not idx.encrypted and not idx.locked)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
