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

# --- run ------------------------------------------------------------------------------

start_yazi
for t in zip_browse zip_preview zip_copy_out zip_paste_in zip_paste_folder zip_overwrite \
	zip_move_in zip_rename zip_create zip_delete zip_trash zip_save_back zip_clean_saves_edits \
	sevenz_browse sevenz_edit tar_browse targz_browse tarzst_browse targz_read_only; do
	run "$t"
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || {
	printf '  %s\n' "${failures[@]}"
	exit 1
}
