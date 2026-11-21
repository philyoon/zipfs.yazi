# zipfs.yazi

Browse `.zip` (and `.jar`) archives in Yazi as if they were folders, using Yazi's custom VFS
(`kind = "mount"`).

Tested on Yazi 26.9.1. The custom VFS API is experimental upstream and may change.

## What works

- Enter a zip with `l`, walk its folders, leave with `h`.
- Preview files inside (text, images, anything Yazi previews), open them with your usual opener.
- Copy files out: yank inside the archive, paste outside.
- Non-ASCII names (Korean, Japanese, ...) and names with `[`, `*`, `?`.
- Zips that leave out directory entries (`zip -D`).
- Edit the archive: trash (`d`), delete (`D`), rename (`r`), new file (`a`), new folder
  (`a` with a trailing `/`). Trash extracts the item and moves it to the macOS Trash before
  removing it from the zip, so it can be recovered as a normal file.
- Paste into the zip: yank (`y`) or cut (`x`) outside, paste (`p`, or `P` to overwrite)
  inside. Folders and binary files work. A cut removes the source only after the copy
  succeeded.

Each edit rewrites the whole zip (that is how the format works), so on a large archive every
edit takes a moment. Deleting a folder with `D` rewrites it once per file inside; trash (`d`)
does it in one pass. Pasting rewrites it about twice per file: once for an empty
placeholder when the file is new, once when its content is complete.

Opened files are saved back. Your opener gets an extracted copy in the cache; when that copy
is newer than its entry, zipfs adds it back into the zip the next time Yazi looks at its
folder:

- A terminal editor (blocking opener): right after you quit it.
- A GUI editor (VS Code etc.): when you switch back to the terminal (needs focus reporting,
  which most terminals have), or when you move to another folder.
- Edits Yazi never got to see: when you enter that zip again, or before the cache is
  cleaned (`g z` or the 7-day cleanup). If saving fails, the copy is kept and you get an
  error.

If the zip itself changes after you opened a file and the zip ends up newer than your edit,
the zip wins and the edited copy is replaced.

If a paste fails (for example the zip's folder is read-only), Yazi's task stays at
"0% - 0B / 0B" instead of reporting an error. It does the same for a read-only plain folder.
Nothing is lost: the source stays, and the zip is unchanged. Cancel the task from the task
list (`w`).

## Requirements

`7zz` in `PATH` (`brew install sevenzip`). Yazi's own archive previewer uses it too.
Trash uses `/usr/bin/trash` (macOS 14+).

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
# Behaves like smart-enter, plus entering zips.
[[mgr.prepend_keymap]]
on   = "l"
run  = "plugin zipfs"
desc = "Enter directory or zip, or open file"

[[mgr.prepend_keymap]]
on   = ["g", "z"]
run  = "plugin zipfs clean"
desc = "Clear the zipfs cache"
```

## How it works

- URLs look like `archive://zip//abs/path/to/file.zip/inner/path`.
- Listing comes from `7zz l -slt` and is cached in `$TMPDIR/yazi-zipfs/<a>-<v>.list`, where
  `<a>` hashes the archive's path and `<v>` its size and mtime, so editing the archive
  invalidates it.
- Entries are extracted to `$TMPDIR/yazi-zipfs/<a>-tree/`. Each extracted file is checked
  against the listing's size and mtime, so one edit doesn't throw away the rest. Each file's
  `backing` points there. Yazi 26.9.1 only allows `download` from SFTP, but previewers, `file --mime-type`
  and opener `%s` all read `backing`, so preview and open go through the extracted copy.
- The fetcher extracts files up to 64 MiB as you scroll. Bigger ones are extracted when
  you open them with `l`.
- Edits run `7zz d` / `7zz rn` / `7zz a` under a per-archive lock folder
  (`<a>-lock.lock`), because Yazi sends one call per file when deleting a folder, in
  parallel.
- Yazi writes a pasted file in chunks, up to 4 at once, each in a fresh plugin call. The
  chunks go into a staging file under `$TMPDIR/yazi-zipfs/writes/`, and the file is added to
  the zip once every byte has arrived.

## Cache

- Old versions of an archive's cache are removed as soon as the archive changes.
- Entering a zip removes cache folders not used for 7 days.
- Edited copies are saved into their zip before either cleanup deletes them.
- `g z` (`plugin zipfs clean`) empties the whole cache, except the zip you are in: Yazi
  doesn't re-detect file types after a clean, so its previews would break.

## Limits

- macOS only for now: trash uses `/usr/bin/trash`. Everything else should work on Linux,
  but it is untested there.
- Nested archives are not entered (a zip inside a zip opens with your opener instead).
- Encrypted entries are not supported.
- Every VFS call re-reads the cached listing (Yazi gives each call a fresh Lua state), so very
  large archives (tens of thousands of entries) will feel slower.

## License

MIT
