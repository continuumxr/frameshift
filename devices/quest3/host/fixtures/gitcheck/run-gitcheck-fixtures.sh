#!/bin/sh
# E1 regression fixtures for fs-gitcheck.sh (FS-R-005 §5 E1). POSIX sh; run
# under dash and bash --posix (test-host2.ps1 runs both through WSL).
#
#   sh run-gitcheck-fixtures.sh [path/to/fs-gitcheck.sh]
#
# Builds throwaway repositories in a fresh mktemp directory (removed at exit),
# never touches the real AOSP checkout. Exit 0 only if every check passes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHK=${1:-$HERE/../../fs-gitcheck.sh}
. "$CHK"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
G() { git -c user.name=fixture -c user.email=fixture@invalid -c init.defaultBranch=main -c core.autocrlf=false "$@"; }

# mkrepo DIR: a repository with two committed files; prints the commit
mkrepo() {
    mkdir -p "$1" && G -C "$1" init -q &&
    printf 'print("mkbootimg")\n' > "$1/mkbootimg.py" &&
    printf 'data\n' > "$1/README" &&
    G -C "$1" add -A && G -C "$1" commit -q -m fixture && G -C "$1" rev-parse HEAD
}
# expect_refused NAME REPO COMMIT [required substring of the refusal]
expect_refused() {
    out=$(fs_gitcheck "$2" "$3" 2>&1); rc=$?
    if [ $rc -ne 0 ] && { [ -z "${4:-}" ] || printf '%s' "$out" | grep -qF -- "$4"; }; then
        ok "$1 (refused: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-150))"
    else bad "$1 (rc=$rc out=$out)"; fi
}

echo "== git: $(git --version)  shell: $(readlink /proc/$$/exe 2>/dev/null || echo sh)"

# 1. positive
C=$(mkrepo "$T/clean")
if fs_gitcheck "$T/clean" "$C" 2>/dev/null; then ok "G1 clean checkout accepted"; else bad "G1 clean checkout accepted"; fi
if fs_gitcheck "$T/clean/" "$C" 2>/dev/null; then ok "G1b trailing slash accepted"; else bad "G1b trailing slash accepted"; fi

# 2-5. the FS-A-004 N-1 cases, kept
C=$(mkrepo "$T/untracked"); printf 'evil\n' > "$T/untracked/hashlib.py"
expect_refused "G2 planted untracked hashlib.py" "$T/untracked" "$C" "hashlib.py"
C=$(mkrepo "$T/modified"); printf 'x\n' >> "$T/modified/mkbootimg.py"
expect_refused "G3 modified tracked file" "$T/modified" "$C" "mkbootimg.py"
C=$(mkrepo "$T/ignored"); printf '*.pyc\n' > "$T/ignored/.git/info/exclude"; printf 'x' > "$T/ignored/gki.pyc"
expect_refused "G4 planted ignored file (info/exclude)" "$T/ignored" "$C" "gki.pyc"
C=$(mkrepo "$T/shownone"); git -C "$T/shownone" config status.showUntrackedFiles no; printf 'evil\n' > "$T/shownone/hashlib.py"
expect_refused "G5 config status.showUntrackedFiles=no cannot hide a planted file" "$T/shownone" "$C" "hashlib.py"

# 6. E1: core.worktree in the checkout's own config redirects status to a clean copy
C=$(mkrepo "$T/e1"); mkdir "$T/e1alt"; cp "$T/e1/mkbootimg.py" "$T/e1/README" "$T/e1alt/"
printf 'evil\n' > "$T/e1/hashlib.py"
git -C "$T/e1" config core.worktree "$T/e1alt"
AOSP=$T/e1
ag_old() { git -c core.fsmonitor=false -c status.showUntrackedFiles=all -c core.worktree="$AOSP" -C "$AOSP" "$@"; }
old=$(ag_old status --porcelain --ignored --untracked-files=all 2>&1)
if [ -z "$old" ]; then ok "G6c CONTROL: stage-1 ag() reports the redirected checkout clean (E1 reproduced on this git)"
else bad "G6c CONTROL: stage-1 ag() was expected to be blinded; it printed: $old"; fi
expect_refused "G6 core.worktree redirect: refused (config entry)" "$T/e1" "$C" "core.worktree is set"
expect_refused "G6b core.worktree redirect: explicit --work-tree status sees the planted file" "$T/e1" "$C" "hashlib.py"

# 6d. core.worktree arriving through an include file
C=$(mkrepo "$T/e1inc"); mkdir "$T/e1incalt"; cp "$T/e1inc/mkbootimg.py" "$T/e1inc/README" "$T/e1incalt/"
printf '[core]\n\tworktree = %s\n' "$T/e1incalt" > "$T/inc.cfg"
git -C "$T/e1inc" config include.path "$T/inc.cfg"; printf 'evil\n' > "$T/e1inc/hashlib.py"
expect_refused "G6d core.worktree via include.path" "$T/e1inc" "$C" "core.worktree is set"

# 7-8. caller environment
C=$(mkrepo "$T/envwt"); mkdir "$T/envwtalt"; cp "$T/envwt/mkbootimg.py" "$T/envwt/README" "$T/envwtalt/"
printf 'evil\n' > "$T/envwt/hashlib.py"
blind=$(GIT_WORK_TREE="$T/envwtalt" git -C "$T/envwt" status --porcelain --untracked-files=all 2>&1)
[ -z "$blind" ] && ok "G7c CONTROL: GIT_WORK_TREE blinds a plain status" || bad "G7c CONTROL: GIT_WORK_TREE expected to blind ($blind)"
out=$(GIT_WORK_TREE="$T/envwtalt" fs_gitcheck "$T/envwt" "$C" 2>&1) && bad "G7 GIT_WORK_TREE in the caller's environment ignored" \
    || { printf '%s' "$out" | grep -qF hashlib.py && ok "G7 GIT_WORK_TREE in the caller's environment ignored (planted file found)" || bad "G7 ($out)"; }
C2=$(mkrepo "$T/envgd"); printf 'evil\n' > "$T/envgd/hashlib.py"
out=$(GIT_DIR="$T/clean/.git" GIT_INDEX_FILE="$T/clean/.git/index" fs_gitcheck "$T/envgd" "$C2" 2>&1) && bad "G8 GIT_DIR/GIT_INDEX_FILE in the caller's environment ignored" \
    || { printf '%s' "$out" | grep -qF hashlib.py && ok "G8 GIT_DIR/GIT_INDEX_FILE in the caller's environment ignored" || bad "G8 ($out)"; }
CC=$(git -C "$T/clean" rev-parse HEAD)
if (export GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent; fs_gitcheck "$T/clean" "$CC") 2>/dev/null; then ok "G8b positive despite a bogus GIT_DIR in the caller"; else bad "G8b positive despite a bogus GIT_DIR"; fi

# 9-11. index flags and hooks
C=$(mkrepo "$T/au"); git -C "$T/au" update-index --assume-unchanged mkbootimg.py; printf 'x\n' >> "$T/au/mkbootimg.py"
expect_refused "G9 assume-unchanged entry" "$T/au" "$C" "assume-unchanged"
C=$(mkrepo "$T/sw"); git -C "$T/sw" update-index --skip-worktree README
expect_refused "G10 skip-worktree entry" "$T/sw" "$C" "skip-worktree"
C=$(mkrepo "$T/fsm"); printf '#!/bin/sh\ntouch "%s/FSMONITOR_RAN"\nprintf "\\0"\n' "$T" > "$T/fsm-hook"; chmod +x "$T/fsm-hook"
git -C "$T/fsm" config core.fsmonitor "$T/fsm-hook"; printf 'x\n' >> "$T/fsm/README"
expect_refused "G11 fsmonitor hook configured: modification still found" "$T/fsm" "$C" "README"
[ -e "$T/FSMONITOR_RAN" ] && bad "G11b the configured fsmonitor hook was executed" || ok "G11b the configured fsmonitor hook was not executed"

# 12-16. identity and form
C=$(mkrepo "$T/head"); printf 'y\n' > "$T/head/README"; G -C "$T/head" commit -q -am second
expect_refused "G12 HEAD is not the pinned commit" "$T/head" "$C" "not the pinned"
C=$(mkrepo "$T/gfreal"); mkdir "$T/gf"; cp "$T/gfreal/mkbootimg.py" "$T/gfreal/README" "$T/gf/"; printf 'gitdir: %s/.git\n' "$T/gfreal" > "$T/gf/.git"
expect_refused "G13 .git is a gitfile" "$T/gf" "$C" "gitfile"
C=$(mkrepo "$T/slreal"); mkdir "$T/sl"; cp "$T/slreal/mkbootimg.py" "$T/slreal/README" "$T/sl/"; ln -s "$T/slreal/.git" "$T/sl/.git"
if [ -L "$T/sl/.git" ]; then expect_refused "G14 .git is a symlink" "$T/sl" "$C" "symlink"
else echo "INFO  G14 ln -s made a copy, not a link, on this platform (MSYS): skipped"; fi
C=$(git -C "$T/clean" rev-parse HEAD)
out=$(cd "$T" && fs_gitcheck clean "$C" 2>&1) && bad "G15 relative path refused" || ok "G15 relative path refused"
expect_refused "G16 malformed pinned commit" "$T/clean" "ABCDEF" "hex"
expect_refused "G16b short pinned commit" "$T/clean" "$(printf '%s' "$C" | cut -c1-12)" "40 hex"

# ---- revision 2: bypasses found by the adversarial review of da0ad56 (SHOULD-FIX 2) ----
# old-style view (git's own status, caller environment) for the controls
oldview() { git -C "$1" -c core.fsmonitor=false -c status.showUntrackedFiles=all status --porcelain --ignored --untracked-files=all 2>&1; }
# G17 git replace: HEAD == pin, status clean, but a file is the evil commit's
C=$(mkrepo "$T/rep"); printf 'EVIL\n' > "$T/rep/mkbootimg.py"; G -C "$T/rep" commit -q -am evil; E=$(git -C "$T/rep" rev-parse HEAD)
G -C "$T/rep" reset -q --soft "$C"; git -C "$T/rep" replace "$C" "$E"; git -C "$T/rep" update-index -q --refresh
[ -z "$(oldview "$T/rep")" ] && [ "$(git -C "$T/rep" rev-parse HEAD)" = "$C" ] && ok "G17c CONTROL: with a replace ref, HEAD == pin and status is clean" || bad "G17c CONTROL: replace did not blind status ($(oldview "$T/rep"))"
expect_refused "G17 git replace <pin> <evil>: refused (replace ref)" "$T/rep" "$C" "replace refs present"
expect_refused "G17b git replace: content compared without replacement" "$T/rep" "$C" "file content differs"
# G18 clean filter (repository config + info/attributes) hides a modification
C=$(mkrepo "$T/flt"); cp "$T/flt/mkbootimg.py" "$T/flt-orig"; printf 'import evil\n' >> "$T/flt/mkbootimg.py"
git -C "$T/flt" config filter.hide.clean "cat >/dev/null; cat '$T/flt-orig'"; printf 'mkbootimg.py filter=hide\n' > "$T/flt/.git/info/attributes"
git -C "$T/flt" add mkbootimg.py
if [ -z "$(oldview "$T/flt")" ]; then ok "G18c CONTROL: the clean filter hides the modification from status"; else echo "INFO  G18c filter did not blind status on this git ($(oldview "$T/flt" | tr '\n' ';'))"; fi
expect_refused "G18 clean filter: content compared with --no-filters" "$T/flt" "$C" "file content differs"
# G19 core.fileMode=false hides a mode change (needs a file system with exec bits)
C=$(mkrepo "$T/fm"); git -C "$T/fm" config core.fileMode false; chmod +x "$T/fm/README"
note=$(fs_gitcheck "$T/fm" "$C" 2>&1 | grep '^NOTE: mode bits not checkable')
if [ -n "$note" ]; then
    out=$(fs_gitcheck "$T/fm" "$C" 2>&1); printf '%s' "$out" | grep -q 'mode differs' && bad "G19 mode check claimed on a file system without exec bits" || ok "G19 no exec bits here: reported ($note), not claimed"
else
    [ -z "$(oldview "$T/fm")" ] && ok "G19c CONTROL: core.fileMode=false hides the mode change from status" || bad "G19c CONTROL ($(oldview "$T/fm"))"
    expect_refused "G19 mode bits read from the file system, not core.fileMode" "$T/fm" "$C" "mode differs (pinned 100644, file executable)"
fi
# G20/G21 configuration from the caller's environment: GIT_CONFIG_GLOBAL, HOME
C=$(mkrepo "$T/envg"); cp "$T/envg/mkbootimg.py" "$T/envg-orig"; printf 'import evil\n' >> "$T/envg/mkbootimg.py"
printf 'mkbootimg.py filter=hide\n' > "$T/envg-attr"
printf '[core]\n\tattributesFile = %s\n[filter "hide"]\n\tclean = "%s"\n' "$T/envg-attr" "cat >/dev/null; cat $T/envg-orig" > "$T/envg-cfg"
GIT_CONFIG_GLOBAL="$T/envg-cfg" git -C "$T/envg" add mkbootimg.py
if [ -z "$(GIT_CONFIG_GLOBAL="$T/envg-cfg" oldview "$T/envg")" ]; then ok "G20c CONTROL: GIT_CONFIG_GLOBAL filter hides the modification"; else echo "INFO  G20c not blinded on this git"; fi
out=$(GIT_CONFIG_GLOBAL="$T/envg-cfg" fs_gitcheck "$T/envg" "$C" 2>&1) && bad "G20 GIT_CONFIG_GLOBAL from the caller is ignored" \
    || { printf '%s' "$out" | grep -q "file content differs" && ok "G20 GIT_CONFIG_GLOBAL from the caller is ignored (difference found)" || bad "G20 ($out)"; }
mkdir -p "$T/fakehome"; cp "$T/envg-cfg" "$T/fakehome/.gitconfig"
out=$(HOME="$T/fakehome" XDG_CONFIG_HOME="$T/fakehome" fs_gitcheck "$T/envg" "$C" 2>&1) && bad "G21 HOME/.gitconfig from the caller is ignored" \
    || { printf '%s' "$out" | grep -q "file content differs" && ok "G21 HOME/.gitconfig from the caller is ignored (difference found)" || bad "G21 ($out)"; }
# G22/G23 object substitution files
C=$(mkrepo "$T/alt"); mkdir -p "$T/alt/.git/objects/info"; printf '%s\n' "$T/clean/.git/objects" > "$T/alt/.git/objects/info/alternates"
expect_refused "G22 objects/info/alternates present" "$T/alt" "$C" "alternates exists"
C=$(mkrepo "$T/grf"); printf '%s\n' "$C" > "$T/grf/.git/info/grafts"
expect_refused "G23 info/grafts present" "$T/grf" "$C" "grafts exists"
# G24 a nested repository hides its files from status; the file-system walk finds them
C=$(mkrepo "$T/nest"); mkdir -p "$T/nest/gki"; G -C "$T/nest/gki" init -q; printf 'evil\n' > "$T/nest/gki/hashlib.py"; G -C "$T/nest/gki" add -A; G -C "$T/nest/gki" commit -q -m n
expect_refused "G24 nested repository with a planted file" "$T/nest" "$C" "gki/hashlib.py"
# G25 a tracked symlink: refused whether or not it was retargeted (fix round 6; before: G25a accepted it)
C2=$(mkdir -p "$T/sym" && G -C "$T/sym" init -q && printf 'x\n' > "$T/sym/real.py" && printf 'y\n' > "$T/sym/other.py" && ln -s real.py "$T/sym/link.py" && G -C "$T/sym" add -A && G -C "$T/sym" commit -q -m s && git -C "$T/sym" rev-parse HEAD)
if [ -L "$T/sym/link.py" ]; then
    expect_refused "G25a tracked symlink, unchanged" "$T/sym" "$C2" "symlink entry in the pinned tree"
    rm "$T/sym/link.py"; ln -s other.py "$T/sym/link.py"
    expect_refused "G25 tracked symlink retargeted" "$T/sym" "$C2" "symlink entry in the pinned tree"
else echo "INFO  G25 symlinks not created on this platform (skipped)"; fi

echo "TOTAL: $pass passed, $fail failed"
[ $fail -eq 0 ]
