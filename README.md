# zipfs.yazi

[![test](https://github.com/philyoon/zipfs.yazi/actions/workflows/test.yml/badge.svg)](https://github.com/philyoon/zipfs.yazi/actions/workflows/test.yml)

A lightweight, 7zz-based archive filesystem for Yazi: enter zip, 7z, rar and tar files as
folders, and edit zip and 7z in place.

Plain Lua and `7zz`, nothing else to build or install. It uses Yazi's custom VFS
(`kind = "mount"`), so inside an archive Yazi's normal keys just work: preview, open, copy,
paste, rename, delete.

Tested on Yazi 26.9.1, on macOS and Linux (CI runs both). The custom VFS API is experimental upstream and may change.

## Formats

| Format | Browse, preview, open, copy out | Edit |
| --- | --- | --- |
| zip, and zips by another name: jar, war, ear, aar, apk, ipa, xpi, whl, nupkg, vsix, epub, cbz | yes | yes |
| 7z, cb7 | yes | yes |
| rar, cbr | yes | read-only (7zz can't write rar) |
| iso, cab | yes | read-only |
| tar | yes | read-only (7zz can't delete from tar) |
| tar.gz, tgz, tar.bz2, tbz, tbz2, tar.xz, txz, tar.zst, tzst | yes | read-only |

Editing a signed package (apk, ipa, jar) breaks its signature. dmg is left out: 7zz lists
the folders in it as files.

A compressed tar can't be read one file at a time, so the first visit decompresses the
inner tar into the cache. That takes as long as extracting the whole archive once and uses
as much disk space; later visits are fast.

## What works

- Enter an archive with `l`, walk its folders, leave with `h`.
- Preview files inside (text, images, anything Yazi previews), open them with your usual
  opener.
- Copy files out: yank inside the archive, paste outside.
- Non-ASCII names (Korean, Japanese, ...) and names with `[`, `*`, `?`.
- Zips that leave out directory entries (`zip -D`).
- Zips made by macOS Finder: the `__MACOSX/` folder and `._name` files (Finder metadata)
  are hidden, and follow their item when you rename, delete or trash it.
- Check an archive for damage with `g t` (`plugin zipfs test`, which runs `7zz t`): on
  the hovered archive, or the one you are in.
- Edit zip and 7z: trash (`d`), delete (`D`), rename (`r`), new file (`a`), new folder (`a`
  with a trailing `/`). Trash extracts the item and moves it to the system trash before
  removing it from the archive, so it can be recovered as a normal file.
- Paste into zip and 7z: yank (`y`) or cut (`x`) outside, paste (`p`, or `P` to overwrite)
  inside. Folders and binary files work. A cut removes the source only after the copy
  succeeded.
- Save opened files back into zip and 7z (see below).
- Encrypted zip and 7z, including 7z with encrypted file names (see below).

Each edit rewrites the whole archive (that is how zip and 7z work), so on a large archive
every edit takes a moment. Deleting a folder with `D` rewrites it once per file inside;
trash (`d`) does it in one pass. Pasting rewrites it about twice per file: once for an
empty placeholder when the file is new, once when its content is complete.

### Saving opened files back

Your opener gets an extracted copy in the cache. When that copy is newer than its entry,
zipfs adds it back into the archive the next time Yazi looks at its folder:

- A terminal editor (blocking opener): right after you quit it.
- A GUI editor (VS Code etc.): when you switch back to the terminal (needs focus reporting,
  which most terminals have), or when you move to another folder.
- Edits Yazi never got to see: when you enter that archive again, or before the cache is
  cleaned (`g z` or the 7-day cleanup). If saving fails, the copy is kept and you get an
  error.

If the archive itself changes after you opened a file and ends up newer than your edit, the
archive wins and the edited copy is replaced. In read-only formats an edit stays in the
cached copy only.

### Encrypted archives

Pressing `l` on an encrypted archive asks for its password, and so does opening an
encrypted file inside when zipfs doesn't have it yet. A wrong password gets two more
tries. Then everything works as usual, edits included: added and saved files are
encrypted with the same password, AES zips stay AES, and a 7z with encrypted names keeps
them encrypted.

- The password stays in Yazi's memory only. It reaches `7zz` on stdin, never on the command
  line.
- Extracted copies in the cache are decrypted, so they live only while you are inside.
- Leaving the archive (no tab is inside it any more) locks it: edits are saved, the
  decrypted copies and the listing are deleted, and the password is forgotten. Entering
  again asks again.
- Quitting with `q` / `Q` bound to `plugin zipfs quit` (see Setup) locks every archive
  first. If Yazi then asks whether to quit with tasks running and you say no, enter the
  archive again.
- If Yazi dies without that (killed, terminal closed), the next `l` on an archive deletes
  the copies it left. Edited copies that could not be saved stay until you enter that
  archive again, which saves them.
- `g z` forgets every password except the one for the archive you are in.
- An archive entered another way than `l` (for example `cd`) is listed, but its files
  can't be previewed until you enter it with `l` or open one of them.
- One password per archive: files with different passwords in one zip are not supported.

If a paste fails (for example the archive's folder is read-only), Yazi's task stays at
"0% - 0B / 0B" instead of reporting an error. It does the same for a read-only plain folder.
Nothing is lost: the source stays, and the archive is unchanged. Cancel the task from the
task list (`w`).

## Requirements

- `7zz` in `PATH`: `brew install sevenzip` on macOS; on Linux, the `7zip` package (link its
  `7z` as `7zz` if it doesn't install one). Yazi's own archive previewer uses it too.
- For trash (`d`), one of: `trash` (built into macOS 14+, or trash-cli on Linux), `gio`
  (GLib), or `trash-put` (trash-cli). Without any of them, `D` still deletes.

## Setup

```sh
ya pkg add philyoon/zipfs
```

Then add these three pieces of config:

`~/.config/yazi/vfs.toml`

```toml
[archive.zip]
kind = "mount"
run  = "zipfs"
```

`~/.config/yazi/yazi.toml`

```toml
# Files inside a mount match none of the built-in mime fetchers, so without this
# there is no preview and no opener rule.
[[plugin.prepend_fetchers]]
url   = "archive://*"
run   = "zipfs"
prio  = "high"
group = "mime"
```

`~/.config/yazi/keymap.toml`

```toml
# Behaves like smart-enter, plus entering archives.
[[mgr.prepend_keymap]]
on   = "l"
run  = "plugin zipfs"
desc = "Enter directory or archive, or open file"

[[mgr.prepend_keymap]]
on   = ["g", "z"]
run  = "plugin zipfs clean"
desc = "Clear the zipfs cache"

[[mgr.prepend_keymap]]
on   = ["g", "t"]
run  = "plugin zipfs test"
desc = "Check the archive for damage"

# Locks encrypted archives (deletes their decrypted copies) before quitting.
[[mgr.prepend_keymap]]
on   = "q"
run  = "plugin zipfs quit"
desc = "Quit"

[[mgr.prepend_keymap]]
on   = "Q"
run  = "plugin zipfs -- quit --no-cwd-file"
desc = "Quit without writing cwd-file"
```

## How it works

- The code is split by who needs it: `main.lua` answers Yazi's VFS calls and the fetcher
  with `core.lua` (formats, 7zz, cache, listings, extraction) and `edit.lua` (changes);
  `cmds.lua` holds what only `plugin zipfs` runs (entering, passwords, locking, cleanup),
  so VFS calls don't load it. `state.lua` holds every `ya.sync`, since each file gets its
  own plugin state.
- URLs look like `archive://zip//abs/path/to/file.7z/inner/path` (the mount is called
  `zip` whatever the format).
- Listing comes from `7zz l -slt` and is cached in `$TMPDIR/yazi-zipfs/<a>-<v>.list`, where
  `<a>` hashes the archive's path and `<v>` its size and mtime, so editing the archive
  invalidates it.
- Entries are extracted to `$TMPDIR/yazi-zipfs/<a>-tree/`. Each extracted file is checked
  against the listing's size and mtime, so one edit doesn't throw away the rest. Each file's
  `backing` points there. Yazi 26.9.1 only allows `download` from SFTP, but previewers,
  `file --mime-type` and opener `%s` all read `backing`, so preview and open go through the
  extracted copy.
- The fetcher extracts files up to 64 MiB as you scroll. Bigger ones are extracted when
  you open them with `l`.
- Edits run `7zz d` / `7zz rn` / `7zz a` under a per-archive lock folder
  (`<a>-lock.lock`), because Yazi sends one call per file when deleting a folder, in
  parallel.
- Yazi writes a pasted file in chunks, up to 4 at once, each in a fresh plugin call. The
  chunks go into a staging file under `$TMPDIR/yazi-zipfs/writes/`, and the file is added to
  the archive once every byte has arrived.

## Cache

- Old versions of an archive's cache are removed as soon as the archive changes.
- Entering an archive removes cache entries not used for 7 days.
- Edited copies are saved into their archive before either cleanup deletes them.
- `g z` (`plugin zipfs clean`) empties the whole cache, except the archive you are in: Yazi
  doesn't re-detect file types after a clean, so its previews would break.

## Limits

- Nested archives are not entered (a zip inside a zip opens with your opener instead).
- A file of your own named `._something` inside an archive is hidden like Finder metadata.
- Every VFS call re-reads the cached listing (Yazi gives each call a fresh Lua state), so
  very large archives (tens of thousands of entries) will feel slower.
- Solid 7z and rar archives decompress everything before a file to reach it, so previews
  in big solid archives are slow.

## Development

```sh
mise install         # Lua 5.4 (what Yazi embeds) and StyLua, pinned in mise.toml
lua tests/unit.lua   # listing parser and format table
stylua .             # format (stylua.toml: Yazi's settings, 2-space indent)
tests/e2e.sh         # a real Yazi in tmux, driven with `ya emit-to`
```

The end-to-end tests need `yazi`, `ya`, `7zz`, `tmux` and `zstd`, and run everything in a
temp folder: their own Yazi config, plugin cache and archives, plus stub `trash` and editor
commands. `tests/e2e.sh zip_` runs only the tests whose names start with `zip_`;
`E2E_KEEP=1` keeps the temp folder. CI runs both on Ubuntu and macOS with Yazi 26.9.1.

## See also

[zippity](https://github.com/hawkff/zippity) covers far more (dmg and disk images, nested
archives, split volumes, creating and re-encrypting archives) with a Rust helper and
explicit edit sessions.
zipfs stays small: plain Lua, Yazi's own keys, and edits that apply at once.

## License

MIT
