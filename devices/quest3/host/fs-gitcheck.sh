#!/bin/sh
# FrameShift E1: clean-checkout check for a pinned third-party git checkout
# (POSIX sh; the builder runs it under bash in WSL). Twin of fs-gitcheck.ps1.
#
# FS-A-005 §8 E1 / FS-R-005 §5 E1 (accepted): `-c core.worktree="$AOSP"` does
# NOT override a core.worktree set in the checkout's own .git/config. The
# correction:
#   - git --git-dir="$REPO/.git" --work-tree="$REPO" on every call;
#   - GIT_DIR and GIT_WORK_TREE unset;
#   - a core.worktree regression negative (fixtures/gitcheck/).
#
# Revision 2 (adversarial review of da0ad56, SHOULD-FIX 2). Git's own view of
# "clean" is no longer trusted:
#   - GIT_NO_REPLACE_OBJECTS=1, and any refs/replace/* is refused;
#   - .git/info/grafts and .git/objects/info/alternates are refused;
#   - only the repository's own config is read: GIT_CONFIG_NOSYSTEM=1,
#     GIT_CONFIG_GLOBAL=/dev/null; GIT_CONFIG_SYSTEM, GIT_ATTR_SOURCE, HOME,
#     XDG_CONFIG_HOME, GIT_REPLACE_REF_BASE unset;
#   - every blob of the pinned tree (ls-tree -r <pin>) is compared with
#     `git hash-object --no-filters` of the work-tree file (clean filters,
#     attributes, autocrlf cannot hide a difference); symlink entries are
#     refused (fix round 6: as in fs-gitcheck.ps1);
#   - mode bits are read from the file system (not core.fileMode): 100755
#     must be executable, 100644 must not. Where the file system stores no
#     exec bits (WSL drvfs without "metadata", Git Bash/MSYS) this is
#     reported ("NOTE: mode bits not checkable here"), not silently passed;
#   - a file-system walk (find), independent of git's index and ignore
#     rules, refuses any file or link not in the pinned tree;
#   - submodule entries are refused.
# Kept: HEAD = the pinned commit, core.worktree in the repository config
# refused, status --porcelain --ignored --untracked-files=all empty,
# ls-files -v only "H ", rev-parse top level / git dir, .git a real directory.
#
# Use from a builder (replaces ag() and its three checks):
#   . "$ROOT/devices/quest3/host/fs-gitcheck.sh"
#   fs_gitcheck "$AOSP" "$EXPECT_AOSP" || die "AOSP mkbootimg checkout refused (see above)"
# Or run directly: sh fs-gitcheck.sh REPO EXPECT_COMMIT   (exit 0 clean, 1 refused, 64 usage)
#
# Every failed check prints one "REFUSED: ..." line on stderr; all checks run.

fs_gitcheck() (
    # a subshell: the environment changes and helpers do not leak to the caller
    unset GIT_DIR GIT_WORK_TREE \
          GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
          GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
          GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG GIT_CONFIG_SYSTEM \
          GIT_ATTR_SOURCE GIT_REPLACE_REF_BASE HOME XDG_CONFIG_HOME GIT_EXTERNAL_DIFF
    GIT_NO_REPLACE_OBJECTS=1; GIT_CONFIG_NOSYSTEM=1; GIT_CONFIG_GLOBAL=/dev/null; GIT_OPTIONAL_LOCKS=0
    export GIT_NO_REPLACE_OBJECTS GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_OPTIONAL_LOCKS
    repo=$1; want=$2; bad=0
    r() { echo "REFUSED: $*" >&2; bad=1; }
    case "$want" in
        *[!0-9a-f]*|'') r "pinned commit is not lowercase hex"; return 1 ;;
    esac
    [ ${#want} -eq 40 ] || { r "pinned commit is not 40 hex characters"; return 1; }
    case "$repo" in /*) ;; *) r "repository path is not absolute: $repo"; return 1 ;; esac
    repo=${repo%/}
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)   # native git.exe prints and opens C:/ paths, not MSYS ones
            command -v cygpath >/dev/null 2>&1 && repo=$(cygpath -m "$repo") ;;
    esac
    gd=$repo/.git
    if [ -L "$gd" ]; then r ".git is a symlink, not a real directory"; return 1; fi
    if [ -f "$gd" ]; then r ".git is a file (gitfile redirect), not a directory"; return 1; fi
    [ -d "$gd" ] || { r "no .git directory in $repo"; return 1; }
    for f in info/grafts objects/info/alternates; do
        if [ -e "$gd/$f" ] || [ -L "$gd/$f" ]; then r ".git/$f exists (object substitution)"; fi
    done
    tmp=$(mktemp -d) || { r "mktemp failed"; return 1; }
    trap 'rm -rf "$tmp"' EXIT

    g() { git --git-dir="$gd" --work-tree="$repo" -c core.fsmonitor=false -c status.showUntrackedFiles=all "$@"; }

    wt=$(git config --file "$gd/config" --includes --get-all core.worktree); rc=$?
    if [ $rc -eq 0 ] && [ -n "$wt" ]; then r "core.worktree is set in the repository config: $wt"
    elif [ $rc -ne 0 ] && [ $rc -ne 1 ]; then r "git config read failed (rc $rc)"; fi

    rep=$(g for-each-ref --format='%(refname)' refs/replace/) || r "for-each-ref refs/replace failed"
    [ -z "$rep" ] || r "replace refs present (refs/replace): $(printf '%s\n' "$rep" | head -n 3 | tr '\n' ';')"
    top=$(g rev-parse --show-toplevel) || r "rev-parse --show-toplevel failed"
    [ "$top" = "$repo" ] || r "work tree is '$top', not $repo"
    agd=$(g rev-parse --absolute-git-dir) || r "rev-parse --absolute-git-dir failed"
    [ "$agd" = "$gd" ] || r "git dir is '$agd', not $gd"
    head=$(g rev-parse --verify 'HEAD^{commit}') || r "rev-parse HEAD failed"
    [ "$head" = "$want" ] || r "HEAD is '$head', not the pinned $want"
    st=$(g status --porcelain --ignored --untracked-files=all) || r "status failed"
    [ -z "$st" ] || r "working tree is modified (ignored and untracked files included): $(printf '%s\n' "$st" | head -n 5 | tr '\n' ';')"
    lsv=$(g ls-files -v) || r "ls-files failed"
    odd=$(printf '%s\n' "$lsv" | grep -v '^H ' | grep -v '^$')
    [ -z "$odd" ] || r "assume-unchanged/skip-worktree entries: $(printf '%s\n' "$odd" | head -n 5 | tr '\n' ';')"

    # --- mode bits: does this file system store them? ---
    modes=enforce
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) modes="skip (MSYS/Git Bash: no exec bits)" ;; esac
    if [ "$modes" = enforce ] && [ -r /proc/mounts ]; then
        mline=$(awk -v p="$repo" '{ m=$2; gsub(/\\040/," ",m); if ((p == m || index(p, m "/") == 1 || m == "/") && length(m) > best) { best=length(m); line=$3 " " $4 } } END { print line }' /proc/mounts)
        case "$mline" in
            9p\ *aname=drvfs*|drvfs\ *) case "$mline" in *metadata*) ;; *) modes="skip (drvfs without metadata: no exec bits)" ;; esac ;;
        esac
    fi
    [ "$modes" = enforce ] || echo "NOTE: mode bits not checkable here: $modes" >&2

    # --- every entry of the pinned tree against the file system, no filters ---
    if ! g ls-tree -r --full-tree "$want^{tree}" > "$tmp/tree"; then r "ls-tree of the pinned commit failed"
    else
        : > "$tmp/paths"; : > "$tmp/want"
        while IFS= read -r line; do
            meta=${line%%"	"*}; path=${line#*"	"}
            set -- $meta; mode=$1; type=$2; sha=$3
            case "$path" in \"*) r "tracked path needs quoting (unusual characters): $path"; continue ;; esac
            [ "$type" = blob ] || { r "non-blob entry in the pinned tree ($type): $path"; continue; }
            f=$repo/$path
            case "$mode" in
                120000)
                    # fix round 6 (e2e nit): refused outright, like fs-gitcheck.ps1. A link can
                    # point outside the checkout; the pinned AOSP tree has none.
                    r "symlink entry in the pinned tree (not supported by this check): $path"; continue ;;
                100644|100755)
                    if [ -L "$f" ] || [ ! -f "$f" ]; then r "tracked path is not a regular file (or missing): $path"; continue; fi
                    if [ "$modes" = enforce ]; then
                        if [ "$mode" = 100755 ] && [ ! -x "$f" ]; then r "mode differs (pinned 100755, file not executable): $path"; fi
                        if [ "$mode" = 100644 ] && [ -x "$f" ]; then r "mode differs (pinned 100644, file executable): $path"; fi
                    fi
                    printf '%s\n' "$f" >> "$tmp/paths"; printf '%s %s\n' "$sha" "$path" >> "$tmp/want" ;;
                *) r "unexpected mode $mode: $path" ;;
            esac
        done < "$tmp/tree"
        if [ -s "$tmp/paths" ]; then
            if g hash-object --no-filters --stdin-paths < "$tmp/paths" > "$tmp/got"; then
                diffp=$(paste -d ' ' "$tmp/got" "$tmp/want" | awk '$1 != $2 { print $3 }' | head -n 5 | tr '\n' ';')
                [ "$(wc -l < "$tmp/got")" -eq "$(wc -l < "$tmp/want")" ] || r "hash-object returned the wrong number of lines"
                [ -z "$diffp" ] || r "file content differs from the pinned tree (no filters): $diffp"
            else r "hash-object --no-filters failed"; fi
        fi
        # --- file-system walk: anything on disk that is not in the pinned tree ---
        cut -f2 "$tmp/tree" | sort > "$tmp/tracked"
        nested=$(cd "$repo" && find . -path ./.git -prune -o -name .git -print | sed 's#^\./##' | head -n 5 | tr '\n' ';')
        [ -z "$nested" ] || r "nested repository in the checkout: $nested"
        ( cd "$repo" && find . -path ./.git -prune -o -name .git -prune -o \( -type f -o -type l \) -print ) | sed 's#^\./##' | sort > "$tmp/disk"
        extra=$(comm -13 "$tmp/tracked" "$tmp/disk" | head -n 5 | tr '\n' ';')
        [ -z "$extra" ] || r "files not in the pinned tree (file-system walk): $extra"
    fi
    return $bad
)

# Direct execution (not when sourced): sh fs-gitcheck.sh REPO EXPECT_COMMIT
case "${0##*/}" in
    fs-gitcheck.sh)
        if [ $# -ne 2 ]; then echo "usage: fs-gitcheck.sh REPO EXPECT_COMMIT" >&2; exit 64; fi
        if fs_gitcheck "$1" "$2"; then echo "CLEAN $1 at $2"; exit 0; else exit 1; fi ;;
esac
