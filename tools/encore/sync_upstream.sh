#!/usr/bin/env bash
# Takes zmsl/hekili's latest into Encore. A fresh upstream checkout is renamed with tools/encore/rename.py, committed on
# the vendor branch upstream-renamed, and merged into the current branch, so git sees only what upstream changed, in
# Encore's names. Run from a full (not shallow) clone with a clean tree: tools/encore/sync_upstream.sh [upstream ref]
# What Encore cut (tools/encore/cuts.txt) stays cut: an upstream edit to a cut file or a new file under a cut path is
# removed from the merge. Any other conflict is left for you to resolve, then `git commit`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ref=${1:-forever}
url=${ENCORE_UPSTREAM:-https://github.com/zmsl/hekili} # a local path works too (for a rehearsal)
[ -z "$(git status --porcelain)" ] || {
    echo "sync: commit or stash your changes first"
    exit 1
}
git rev-parse --verify -q upstream-renamed >/dev/null || {
    echo "sync: no upstream-renamed branch (it starts at the commit 'Encore: rename Hekili Forever to Encore')"
    exit 1
}
here=$(git branch --show-current)

git fetch "$url" "$ref"
up=$(git rev-parse FETCH_HEAD)
work=$(mktemp -d)
cleanup() {
    git worktree remove --force "$work/up" 2>/dev/null || true
    git worktree remove --force "$work/vendor" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

git worktree add -q --detach "$work/up" "$up"
python3 tools/encore/rename.py "$work/up"
git worktree add -q "$work/vendor" upstream-renamed
# the vendor tree becomes exactly the renamed upstream: clear it, then copy every file upstream tracks
find "$work/vendor" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
(cd "$work/up" && git ls-files -z | tar --null -T - -cf -) | tar -C "$work/vendor" -xf -
git -C "$work/vendor" add -A
if git -C "$work/vendor" diff --cached --quiet; then
    echo "sync: zmsl/hekili $ref at ${up:0:12} holds nothing new"
    exit 0
fi
git -C "$work/vendor" commit -q -m "upstream: zmsl/hekili $ref at ${up:0:12}, renamed by tools/encore/rename.py"
msg="Merge zmsl/hekili ${up:0:12} (renamed) into $here"
git merge --no-ff --no-commit upstream-renamed -m "$msg" || true # conflicts are sorted out below

# Encore's cuts stay cut
mapfile -t cuts < <(grep -v '^#' tools/encore/cuts.txt | sed '/^[[:space:]]*$/d; s/^/:(glob)/')
back=()
while IFS= read -r f; do back+=("$f"); done < <(git ls-files -- "${cuts[@]}" | sort -u)
if [ ${#back[@]} -gt 0 ]; then
    git rm -q -f -- "${back[@]}"
    echo "sync: kept ${#back[@]} cut file(s) cut"
fi

conflicts=$(git diff --name-only --diff-filter=U)
if [ -n "$conflicts" ]; then
    echo "sync: resolve these, then git commit:"
    echo "$conflicts"
    exit 1
fi
git commit -q -m "$msg"
echo "sync: merged zmsl/hekili ${up:0:12}"
