--- Browse archives as folders through Yazi's custom VFS (kind = "mount"): zip and 7z
--- (read and write), rar, iso, cab and tar, plain or compressed (read-only).
---
--- Listing, extraction and edits go through `7zz`, which keeps non-ASCII names intact
--- (`zipinfo`/`unzip` on macOS turn them into "????").
---
--- Supported edits: trash, delete, rename, new folder, new file, paste into the archive. Each
--- one rewrites the whole archive (that is how zip and 7z work), so they are serialized per
--- archive with a lock.
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

local core = require(".core")
local AUTO_EXTRACT_MAX, ENCRYPTED_FOLDER_MAX, writable, err, locate =
	core.AUTO_EXTRACT_MAX, core.ENCRYPTED_FOLDER_MAX, core.writable, core.err, core.locate
local index, lookup, make_file, extracted, extract_many =
	core.index, core.lookup, core.make_file, core.extracted, core.extract_many
local extract = core.extract
local edit = require(".edit")
local remove, rename, create_dir, settle, child_inners =
	edit.remove, edit.rename, edit.create_dir, edit.settle, edit.child_inners
local open_write, set_len, write_chunk, trash, WRITES =
	edit.open_write, edit.set_len, edit.write_chunk, edit.trash, edit.WRITES

local M = {}

function M:provide(job)
	local op = job.op

	local d = op == "Open" and job.demand
	if WRITES[op] or (d and (d.write or d.append or d.create or d.create_new or d.truncate)) then
		local archive = locate(job.url or job.from)
		if archive and not writable(archive) then
			local e = err("PermissionDenied", "%s is read-only: zipfs can only change zip and 7z", archive)
			return op ~= "Open" and false or nil, e
		end
	end

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
		if saved or old.mtime ~= cha.mtime or old.ctime ~= cha.ctime or old.len ~= cha.len or old.mode ~= cha.mode then
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

		local list, stale, budget = {}, {}, ENCRYPTED_FOLDER_MAX
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
			elseif idx.gen and not info.dir and info.len <= math.min(budget, AUTO_EXTRACT_MAX) and not fs.cha(Url(path)) then
				-- An unlocked archive: its copies were deleted when it was last locked, and
				-- Yazi won't fetch files it has seen before, so extract the folder here.
				stale[#stale + 1], budget = child, budget - info.len
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

function M:entry(job) return require(".cmds").entry(job) end

return M
