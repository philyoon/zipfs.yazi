#!/usr/bin/env bash
# End-to-end tests: run a real Yazi in a detached tmux session and drive it with
# `ya emit-to`, then check the archives with 7zz. Needs yazi + ya, 7zz, tmux, tar, zstd.
#
#   tests/e2e.sh            run every test
#   tests/e2e.sh zip_       run tests whose name starts with zip_
#
# Everything lives in a fresh temp folder: Yazi config, the plugin's cache (TMPDIR), the
# archives. A stub `trash` command records trashed files there instead of using the
# system trash, and a stub editor (blocking opener) appends a line to whatever it opens.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FILTER=${1:-}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zipfs-e2e.XXXXXX")
WORK=$(cd "$WORK" && pwd -P) # macOS: /var -> /private/var, so paths match Yazi's
SOCK="zipfs-e2e-$$"
ID=$(( (RANDOM << 15 | RANDOM) + 100000 ))
TIMEOUT=${E2E_TIMEOUT:-15}

passed=0
failed=0
failures=()

cleanup() {
	TMPDIR="$WORK/tmp/" ya emit-to "$ID" quit >/dev/null 2>&1
	tmux -L "$SOCK" kill-server >/dev/null 2>&1
	if [ "$failed" -eq 0 ] && [ -z "${E2E_KEEP:-}" ]; then
		rm -rf -- "$WORK"
	else
		echo "Work folder kept: $WORK"
	fi
}
trap cleanup EXIT

# --- setup --------------------------------------------------------------------------------

mkdir -p "$WORK"/{cfg/plugins,bin,tmp,trashbin,out,in/folder/sub,src/d,src/한글폴더}
ln -s "$ROOT" "$WORK/cfg/plugins/zipfs.yazi"

cat >"$WORK/cfg/vfs.toml" <<'EOF'
[archive.zip]
kind = "mount"
run  = "zipfs"
EOF

cat >"$WORK/cfg/yazi.toml" <<EOF
[[plugin.prepend_fetchers]]
url   = "archive://*"
run   = "zipfs"
prio  = "high"
group = "mime"

[opener]
edit = [{ run = '$WORK/bin/editor %s', block = true, desc = "test editor" }]

[open]
prepend_rules = [{ url = "*", use = "edit" }]
EOF

cat >"$WORK/bin/trash" <<EOF
#!/bin/sh
mv -- "\$1" "$WORK/trashbin/"
EOF
cat >"$WORK/bin/editor" <<'EOF'
#!/bin/sh
echo "EDITED-BY-TEST" >>"$1"
EOF
chmod +x "$WORK/bin/trash" "$WORK/bin/editor"

# Archive contents
echo "hello from b" >"$WORK/src/b.txt"
echo "keep me" >"$WORK/src/keep.txt"
echo "nested a" >"$WORK/src/d/a.txt"
echo "korean" >"$WORK/src/한글폴더/파일.txt"
# Files to paste in
echo "pasted v1" >"$WORK/in/new.txt"
echo "move me" >"$WORK/in/move.txt"
echo "deep" >"$WORK/in/folder/sub/n.txt"

(
	cd "$WORK/src" || exit 1
	7zz a -tzip "$WORK/work.zip" . >/dev/null
	7zz a -t7z "$WORK/work.7z" . >/dev/null
	export COPYFILE_DISABLE=1 # no ._ files from macOS tar
	tar cf "$WORK/work.tar" .
	tar czf "$WORK/work.tar.gz" .
	tar cf - . | zstd -q -o "$WORK/work.tar.zst"
	cp "$WORK/work.zip" "$WORK/book.epub"
) || {
	echo "Could not build test archives"
	exit 1
}

# A zip as Finder's "Compress" makes it: AppleDouble files beside the items and under
# __MACOSX/, built by hand so the test doesn't need macOS.
(
	mkdir -p "$WORK/mac/d2" "$WORK/mac/__MACOSX/d2" || exit 1
	cd "$WORK/mac" || exit 1
	echo "photo" >photo.txt
	echo "x" >d2/x.txt
	echo "meta" >._photo.txt
	echo "meta" >__MACOSX/._photo.txt
	echo "meta" >__MACOSX/d2/._x.txt
	echo "meta" >__MACOSX/._d2
	7zz a -tzip "$WORK/mac.zip" . >/dev/null
	# Stored (no compression), then one byte flipped inside the data: a CRC error.
	head -c 4000 /dev/zero | tr '\0' 'a' >"$WORK/mac/big.txt"
	7zz a -tzip -mx0 "$WORK/bad.zip" big.txt >/dev/null
	printf 'b' | dd of="$WORK/bad.zip" bs=1 seek=2000 conv=notrunc 2>/dev/null
	# Encrypted: an AES zip, and a 7z whose names are encrypted too.
	mkdir -p "$WORK/enc/d" && cd "$WORK/enc" || exit 1
	echo "top secret" >note.txt
	echo "deep secret" >d/x.txt
	7zz a -tzip -mem=AES256 -psekrit "$WORK/secret.zip" . >/dev/null
	7zz a -t7z -mhe=on -psekrit "$WORK/locked.7z" . >/dev/null
	# ZipCrypto, what `zip -e` and Finder-era tools make.
	mkdir -p "$WORK/zc" && cd "$WORK/zc" || exit 1
	printf '# Plan\n\nzipcrypto secret\n' >PLAN.md
	7zz a -tzip -mem=ZipCrypto -psekrit "$WORK/zc.zip" . >/dev/null
) || {
	echo "Could not build test archives"
	exit 1
}

# --- helpers ------------------------------------------------------------------------------

# Yazi's IPC socket lives in TMPDIR, so ya needs the same one as the Yazi it talks to.
ya_() { TMPDIR="$WORK/tmp/" ya "$@"; }
emit() { ya_ emit-to "$ID" "$@" >/dev/null; }
screen() { tmux -L "$SOCK" capture-pane -p -t e2e; }
keys() { tmux -L "$SOCK" send-keys -t e2e "$@"; }
on_screen() { screen | grep -qF -- "$1"; }
# mount ARCHIVE [INNER] -> the URL of INNER inside ARCHIVE. In ":N:1", N says how many
# trailing path components are inside the archive (without it the whole path is taken as
# the archive itself), and 1 that the last of them is the file's name.
mount() {
	local n=0
	[ -n "${2:-}" ] && n=$(($(printf '%s' "$2" | tr -cd / | wc -c) + 1))
	if [ "$n" -eq 0 ]; then
		printf 'archive://zip/%s' "$1"
	else
		printf 'archive://zip:%d:1/%s/%s' "$n" "$1" "$2"
	fi
}
has() { 7zz l -ba -slt "$1" 2>/dev/null | grep -qxF "Path = $2"; }
cat_in() { 7zz e -so "$1" "$2" 2>/dev/null; }
sum() { cksum <"$1"; }
# field ARCHIVE PATH NAME: a field of one entry in `7zz l -slt`, opened with the test password.
field() {
	echo sekrit | 7zz l -slt -ba "$1" 2>/dev/null |
		awk -v p="Path = $2" -v k="$3 = " '$0 == p { f = 1; next } /^Path = / { f = 0 } f && index($0, k) == 1 { print substr($0, length(k) + 1) }'
}
# Answer zipfs's password prompt.
password() {
	wait_until on_screen "Password for $1" || return 1
	keys "$2" Enter
}

# Cancel an input box: the first Escape only leaves insert mode, and two sent at once
# arrive as Alt+Escape.
cancel() {
	keys Escape
	sleep 0.3
	keys Escape
}

# wait_until CMD...: retry for up to $TIMEOUT seconds.
wait_until() {
	local end=$((SECONDS + TIMEOUT))
	while [ "$SECONDS" -lt "$end" ]; do
		"$@" && return 0
		sleep 0.2
	done
	return 1
}

not() { ! "$@"; }

# Each test is a function; `expect` records a failed condition without stopping it.
current=""
test_failed=0
expect() {
	local what=$1
	shift
	if ! "$@"; then
		echo "  expected: $what"
		test_failed=1
	fi
}

run() {
	local name=$1
	[ -n "$FILTER" ] && [[ $name != "$FILTER"* ]] && return
	current=$name
	test_failed=0
	echo "- $name"
	"$name"
	if [ "$test_failed" -eq 0 ]; then
		passed=$((passed + 1))
	else
		failed=$((failed + 1))
		failures+=("$name")
		screen | sed 's/^/    | /' | head -15
	fi
	emit escape
}

start_yazi() {
	tmux -L "$SOCK" new-session -d -s e2e -x 200 -y 40 \
		"cd '$WORK' && PATH='$WORK/bin:$PATH' TMPDIR='$WORK/tmp/' YAZI_CONFIG_HOME='$WORK/cfg' yazi --client-id $ID"
	if ! wait_until ya_ emit-to "$ID" escape 2>/dev/null; then
		echo "Yazi did not start"
		screen
		exit 1
	fi
}

# Hover a local file and enter it the way `l` does (plugin zipfs).
enter() {
	emit reveal "$1"
	wait_until on_screen "$(basename "$1")"
	emit plugin zipfs
	wait_until on_screen "archive://zip/"
}

# --- tests: zip -------------------------------------------------------------------------

zip_browse() {
	enter "$WORK/work.zip"
	expect "listing shows b.txt" wait_until on_screen "b.txt"
	expect "listing shows the Korean folder" wait_until on_screen "한글폴더"
}

zip_preview() {
	emit reveal "$(mount "$WORK/work.zip" keep.txt)"
	expect "preview of keep.txt" wait_until on_screen "keep me"
	emit cd "$(mount "$WORK/work.zip" d)"
	emit reveal "$(mount "$WORK/work.zip" d/a.txt)"
	expect "preview of a nested file" wait_until on_screen "nested a"
}

zip_copy_out() {
	emit reveal "$(mount "$WORK/work.zip" keep.txt)"
	emit yank
	emit cd "$WORK/out"
	emit paste
	expect "keep.txt copied out" wait_until test -f "$WORK/out/keep.txt"
	expect "copied content" grep -qx "keep me" "$WORK/out/keep.txt"
}

zip_paste_in() {
	emit reveal "$WORK/in/new.txt"
	emit yank
	emit cd "$(mount "$WORK/work.zip")"
	emit paste
	expect "new.txt in the zip" wait_until has "$WORK/work.zip" new.txt
	expect "new.txt content" test "$(cat_in "$WORK/work.zip" new.txt)" = "pasted v1"
}

zip_paste_folder() {
	emit reveal "$WORK/in/folder"
	emit yank
	emit cd "$(mount "$WORK/work.zip")"
	emit paste
	expect "folder/sub/n.txt in the zip" wait_until has "$WORK/work.zip" folder/sub/n.txt
}

zip_overwrite() {
	echo "pasted v2" >"$WORK/in/new.txt"
	emit reveal "$WORK/in/new.txt"
	emit yank
	emit cd "$(mount "$WORK/work.zip")"
	emit paste --force
	content_is_v2() { test "$(cat_in "$WORK/work.zip" new.txt)" = "pasted v2"; }
	expect "new.txt replaced" wait_until content_is_v2
}

zip_move_in() {
	emit reveal "$WORK/in/move.txt"
	emit yank --cut
	emit cd "$(mount "$WORK/work.zip")"
	emit paste
	expect "move.txt in the zip" wait_until has "$WORK/work.zip" move.txt
	expect "source removed" wait_until not test -e "$WORK/in/move.txt"
}

zip_rename() {
	emit reveal "$(mount "$WORK/work.zip" new.txt)"
	wait_until on_screen "new.txt"
	emit rename --empty=all
	sleep 0.5
	keys "renamed.txt" Enter
	expect "renamed.txt exists" wait_until has "$WORK/work.zip" renamed.txt
	expect "new.txt is gone" not has "$WORK/work.zip" new.txt
}

zip_create() {
	emit cd "$(mount "$WORK/work.zip")"
	emit create made/
	expect "folder made" wait_until has "$WORK/work.zip" made
	emit create made/blank.txt
	expect "file made/blank.txt" wait_until has "$WORK/work.zip" made/blank.txt
}

zip_delete() {
	emit reveal "$(mount "$WORK/work.zip" renamed.txt)"
	wait_until on_screen "renamed.txt"
	emit remove --permanently --force
	expect "renamed.txt deleted" wait_until not has "$WORK/work.zip" renamed.txt
}

zip_trash() {
	emit reveal "$(mount "$WORK/work.zip" b.txt)"
	wait_until on_screen "b.txt"
	emit remove --force
	expect "b.txt removed from the zip" wait_until not has "$WORK/work.zip" b.txt
	expect "b.txt in the trash" test -f "$WORK/trashbin/b.txt"
}

zip_save_back() {
	emit cd "$(mount "$WORK/work.zip" d)"
	emit reveal "$(mount "$WORK/work.zip" d/a.txt)"
	wait_until on_screen "nested a"
	emit open
	edited() { cat_in "$WORK/work.zip" d/a.txt | grep -q EDITED-BY-TEST; }
	expect "edit saved into the zip" wait_until edited
}

zip_clean_saves_edits() {
	local src tree
	src=$(grep -lxF "$WORK/work.zip" "$WORK"/tmp/yazi-zipfs/*tree.src 2>/dev/null | head -1)
	tree=${src%.src}
	expect "keep.txt was extracted" test -f "$tree/keep.txt"
	sleep 3 # the copy must be clearly newer than its entry
	echo "CLEAN-EDIT" >>"$tree/keep.txt"
	emit cd "$WORK"
	emit plugin zipfs clean
	saved() { cat_in "$WORK/work.zip" keep.txt | grep -q CLEAN-EDIT; }
	expect "edit saved before the clean" wait_until saved
	expect "zip still valid" 7zz t "$WORK/work.zip" >/dev/null
}

# --- tests: 7z ------------------------------------------------------------------------

sevenz_browse() {
	emit cd "$WORK"
	enter "$WORK/work.7z"
	expect "listing shows d" wait_until on_screen "한글폴더"
	emit reveal "$(mount "$WORK/work.7z" b.txt)"
	expect "preview of b.txt" wait_until on_screen "hello from b"
}

sevenz_edit() {
	emit reveal "$WORK/in/folder/sub/n.txt"
	emit yank
	emit cd "$(mount "$WORK/work.7z")"
	emit paste
	expect "n.txt in the 7z" wait_until has "$WORK/work.7z" n.txt
	emit reveal "$(mount "$WORK/work.7z" b.txt)"
	wait_until on_screen "b.txt"
	emit remove --permanently --force
	expect "b.txt deleted from the 7z" wait_until not has "$WORK/work.7z" b.txt
	expect "7z still valid" 7zz t "$WORK/work.7z" >/dev/null
}

# --- tests: tar (read-only) ---------------------------------------------------------------

tar_browse() {
	emit cd "$WORK"
	enter "$WORK/work.tar"
	expect "listing shows d (./ paths)" wait_until on_screen "한글폴더"
	emit reveal "$(mount "$WORK/work.tar" b.txt)"
	expect "preview of b.txt" wait_until on_screen "hello from b"
}

targz_browse() {
	emit cd "$WORK"
	enter "$WORK/work.tar.gz"
	emit cd "$(mount "$WORK/work.tar.gz" d)"
	emit reveal "$(mount "$WORK/work.tar.gz" d/a.txt)"
	expect "preview inside tar.gz" wait_until on_screen "nested a"
}

tarzst_browse() {
	emit cd "$WORK"
	enter "$WORK/work.tar.zst"
	emit reveal "$(mount "$WORK/work.tar.zst" keep.txt)"
	expect "preview inside tar.zst" wait_until on_screen "keep me"
}

targz_read_only() {
	local before
	before=$(sum "$WORK/work.tar.gz")
	emit reveal "$(mount "$WORK/work.tar.gz" b.txt)"
	wait_until on_screen "b.txt"
	emit remove --permanently --force
	sleep 2
	expect "tar.gz unchanged" test "$(sum "$WORK/work.tar.gz")" = "$before"
}

# --- tests: other names, macOS metadata, integrity ----------------------------------------

epub_browse() {
	emit cd "$WORK"
	enter "$WORK/book.epub"
	emit reveal "$(mount "$WORK/book.epub" keep.txt)"
	expect "preview inside .epub" wait_until on_screen "keep me"
}

macos_hidden() {
	emit cd "$WORK"
	enter "$WORK/mac.zip"
	expect "photo.txt listed" wait_until on_screen "photo.txt"
	expect "__MACOSX hidden" not on_screen "__MACOSX"
	expect "._photo.txt hidden" not on_screen "._photo"
}

macos_rename() {
	emit reveal "$(mount "$WORK/mac.zip" photo.txt)"
	wait_until on_screen "photo.txt"
	emit rename --empty=all
	sleep 0.5
	keys "pic.txt" Enter
	expect "pic.txt exists" wait_until has "$WORK/mac.zip" pic.txt
	expect "._pic.txt moved along" has "$WORK/mac.zip" ._pic.txt
	expect "__MACOSX/._pic.txt moved along" has "$WORK/mac.zip" __MACOSX/._pic.txt
	expect "old metadata gone" not has "$WORK/mac.zip" __MACOSX/._photo.txt
}

macos_delete() {
	emit reveal "$(mount "$WORK/mac.zip" d2)"
	wait_until on_screen "d2"
	emit remove --permanently --force
	expect "d2 deleted" wait_until not has "$WORK/mac.zip" d2/x.txt
	expect "__MACOSX/d2 deleted too" not has "$WORK/mac.zip" __MACOSX/d2/._x.txt
	expect "__MACOSX/._d2 deleted too" not has "$WORK/mac.zip" __MACOSX/._d2
	expect "pic.txt metadata kept" has "$WORK/mac.zip" __MACOSX/._pic.txt
}

test_ok() {
	emit cd "$WORK"
	emit reveal "$WORK/work.7z"
	wait_until on_screen "work.7z"
	emit plugin zipfs test
	expect "reports no errors" wait_until on_screen "work.7z: no errors"
}

test_inside() {
	emit cd "$(mount "$WORK/work.zip" d)"
	wait_until on_screen "a.txt"
	emit plugin zipfs test
	expect "tests the archive it is in" wait_until on_screen "work.zip: no errors"
}

test_damaged() {
	emit cd "$WORK"
	emit reveal "$WORK/bad.zip"
	wait_until on_screen "bad.zip"
	emit plugin zipfs test
	expect "reports damage" wait_until on_screen "bad.zip is damaged"
}

# --- tests: encrypted ----------------------------------------------------------------------

# unlock ARCHIVE: enter it with `l` and give the test password.
unlock() {
	emit cd "$WORK"
	emit reveal "$1"
	wait_until on_screen "$(basename "$1")"
	emit plugin zipfs
	password "$(basename "$1")" sekrit && wait_until on_screen "archive://zip/"
}
# cached ARCHIVE: zipfs still holds extracted (decrypted) copies from it.
cached() {
	local src
	src=$(grep -lxF "$1" "$WORK"/tmp/yazi-zipfs/*tree.src 2>/dev/null | head -1)
	[ -n "$src" ] && [ -n "$(find "${src%.src}" -type f 2>/dev/null | head -1)" ]
}

enc_zip_enter() {
	emit cd "$WORK"
	emit reveal "$WORK/secret.zip"
	wait_until on_screen "secret.zip"
	emit plugin zipfs
	expect "asks for the password" password secret.zip wrong
	expect "says it was wrong" wait_until on_screen "Wrong password"
	cancel
	sleep 1
	expect "cancelling stays outside" not on_screen "archive://zip/"
	emit plugin zipfs
	password secret.zip wrong
	wait_until on_screen "Wrong password"
	keys "sekrit" Enter
	expect "entered" wait_until on_screen "archive://zip/"
	emit reveal "$(mount "$WORK/secret.zip" note.txt)"
	expect "preview of an encrypted file" wait_until on_screen "top secret"
}

enc_leave_locks() {
	expect "decrypted copies while inside" cached "$WORK/secret.zip"
	emit cd "$WORK"
	expect "copies deleted on leaving" wait_until not cached "$WORK/secret.zip"
	expect "nothing decrypted left" not test -n "$(grep -rl "top secret" "$WORK/tmp/yazi-zipfs" 2>/dev/null)"
	emit reveal "$WORK/secret.zip"
	wait_until on_screen "secret.zip"
	emit plugin zipfs
	expect "asks again" password secret.zip sekrit
	expect "entered" wait_until on_screen "archive://zip/"
	emit reveal "$(mount "$WORK/secret.zip" note.txt)"
	expect "preview works again" wait_until on_screen "top secret"
}

enc_zip_paste() {
	emit reveal "$WORK/in/new.txt"
	emit yank
	expect "unlocked" unlock "$WORK/secret.zip"
	emit paste
	expect "new.txt in the zip" wait_until has "$WORK/secret.zip" new.txt
	expect "new.txt encrypted" test "$(field "$WORK/secret.zip" new.txt Encrypted)" = "+"
	expect "with AES like the rest" wait_until eval '[[ "$(field "$WORK/secret.zip" new.txt Method)" == AES* ]]'
}

enc_zip_save_back() {
	emit reveal "$(mount "$WORK/secret.zip" note.txt)"
	wait_until on_screen "top secret"
	emit open
	saved() { echo sekrit | 7zz e -so "$WORK/secret.zip" note.txt 2>/dev/null | grep -q EDITED-BY-TEST; }
	expect "edit saved into the zip" wait_until saved
	expect "still encrypted" test "$(field "$WORK/secret.zip" note.txt Encrypted)" = "+"
}

enc_7z_enter() {
	emit cd "$WORK"
	emit reveal "$WORK/locked.7z"
	wait_until on_screen "locked.7z"
	emit plugin zipfs
	expect "asks for the password" password locked.7z sekrit
	expect "names listed" wait_until on_screen "note.txt"
	emit cd "$(mount "$WORK/locked.7z" d)"
	emit reveal "$(mount "$WORK/locked.7z" d/x.txt)"
	expect "preview inside" wait_until on_screen "deep secret"
}

enc_7z_edit() {
	emit reveal "$WORK/in/new.txt"
	emit yank
	expect "unlocked" unlock "$WORK/locked.7z"
	emit paste
	added() { test "$(field "$WORK/locked.7z" new.txt Encrypted)" = "+"; }
	expect "new.txt added, encrypted" wait_until added
	opens_without_password() { 7zz l -ba "$1" </dev/null >/dev/null 2>&1; }
	expect "names still need the password" not opens_without_password "$WORK/locked.7z"
	emit reveal "$(mount "$WORK/locked.7z" note.txt)"
	wait_until on_screen "note.txt"
	emit remove --permanently --force
	gone() { test -z "$(field "$WORK/locked.7z" note.txt Size)" && test -n "$(field "$WORK/locked.7z" new.txt Size)"; }
	expect "note.txt deleted" wait_until gone
}

enc_clean_forgets() {
	emit cd "$WORK"
	emit plugin zipfs clean
	sleep 1
	emit reveal "$WORK/secret.zip"
	wait_until on_screen "secret.zip"
	emit plugin zipfs
	expect "asks again after a clean" password secret.zip sekrit
	expect "entered" wait_until on_screen "archive://zip/"
}

# `l` on a file in a ZipCrypto zip opens it.
enc_zipcrypto_open() {
	expect "unlocked" unlock "$WORK/zc.zip"
	emit reveal "$(mount "$WORK/zc.zip" PLAN.md)"
	expect "preview" wait_until on_screen "zipcrypto secret"
	emit plugin zipfs
	saved() { echo sekrit | 7zz e -so "$WORK/zc.zip" PLAN.md 2>/dev/null | grep -q EDITED-BY-TEST; }
	expect "opened and saved back" wait_until saved
}

# Opening an encrypted file without the password says why it didn't open.
enc_open_cancel() {
	emit cd "$WORK"
	sleep 1 # let the lock from leaving finish
	emit cd "$(mount "$WORK/zc.zip")"
	emit reveal "$(mount "$WORK/zc.zip" PLAN.md)"
	wait_until on_screen "PLAN.md"
	emit plugin zipfs
	expect "asks for the password" wait_until on_screen "Password for zc.zip"
	cancel
	expect "says it was not opened" wait_until on_screen "Not opened: PLAN.md"
	emit plugin zipfs
	for _ in 1 2 3; do
		password zc.zip wrong
		sleep 0.5
	done
	expect "says the password was wrong" wait_until on_screen "Wrong password for"
	emit cd "$WORK"
}

# Quitting with `plugin zipfs quit` from inside locks the archive. Restarts Yazi.
enc_quit_locks() {
	expect "unlocked" unlock "$WORK/secret.zip"
	emit reveal "$(mount "$WORK/secret.zip" note.txt)"
	expect "preview" wait_until on_screen "top secret"
	expect "copies while inside" wait_until cached "$WORK/secret.zip"
	emit plugin zipfs quit
	# Tasks left from earlier tests (the refused tar.gz delete) make Yazi ask first.
	yazi_gone() { ! tmux -L "$SOCK" has-session -t e2e 2>/dev/null; }
	asks() { yazi_gone || on_screen "[Y]es"; }
	wait_until asks && ! yazi_gone && keys y
	expect "Yazi quit" wait_until yazi_gone
	expect "copies deleted on quit" not cached "$WORK/secret.zip"
	start_yazi
}

# A Yazi killed while inside leaves copies; the next `l` on an archive removes them.
enc_crash_sweep() {
	expect "unlocked" unlock "$WORK/locked.7z"
	emit reveal "$(mount "$WORK/locked.7z" new.txt)"
	wait_until on_screen "pasted"
	expect "copies while inside" cached "$WORK/locked.7z"
	tmux -L "$SOCK" kill-server
	sleep 0.5
	expect "copies survive the crash" cached "$WORK/locked.7z"
	start_yazi
	enter "$WORK/work.zip"
	expect "orphaned copies swept" wait_until not cached "$WORK/locked.7z"
}

# --- run ------------------------------------------------------------------------------

start_yazi
for t in zip_browse zip_preview zip_copy_out zip_paste_in zip_paste_folder zip_overwrite \
	zip_move_in zip_rename zip_create zip_delete zip_trash zip_save_back zip_clean_saves_edits \
	sevenz_browse sevenz_edit tar_browse targz_browse tarzst_browse targz_read_only \
	epub_browse macos_hidden macos_rename macos_delete test_ok test_inside test_damaged \
	enc_zip_enter enc_leave_locks enc_zip_paste enc_zip_save_back enc_7z_enter enc_7z_edit \
	enc_clean_forgets enc_zipcrypto_open enc_open_cancel enc_quit_locks enc_crash_sweep; do
	run "$t"
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || {
	printf '  %s\n' "${failures[@]}"
	exit 1
}
