#!/usr/bin/env bash
# usage: selftest.sh <workflow.yml>
# The checks that need no model and no secret:
# 1. the resolve step, with its own guard self-test, passes on the workflow as written;
# 2. three broken copies of the resolve step each fail that self-test;
# 3. the pin check passes on the pinned commit and fails on each kind of drift.
# shellcheck disable=SC2016 # the mutants match the resolve step's shell text literally
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORKFLOW=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/guard-selftest.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "::error::FAIL $1"; fails=$((fails + 1)); }

mkdir -p "$ROOT/x"
python3 "$HERE/extract.py" "$WORKFLOW" "$ROOT/x"

if out=$(bash "$HERE/setup.sh" "$ROOT/x/resolve.sh" "$ROOT/ok" 2>&1); then pass "resolve self-test"; else fail "resolve self-test: $out"; fi

# name | text to replace (must occur once) | replacement | error the self-test must print
mutant() {
  local name=$1 old=$2 new=$3 want=$4 out
  python3 - "$ROOT/x/resolve.sh" "$ROOT/x/resolve-$name.sh" "$old" "$new" <<'EOF' || { fail "mutant $name no longer applies: update selftest.sh"; return; }
import sys
src, dst, old, new = sys.argv[1:]
text = open(src).read()
if text.count(old) != 1:
    sys.exit(1)
open(dst, "w").write(text.replace(old, new))
EOF
  if out=$(bash "$HERE/setup.sh" "$ROOT/x/resolve-$name.sh" "$ROOT/$name" 2>&1); then
    fail "mutant $name: the self-test passed a broken guard"
  elif [[ "$out" == *"$want"* ]]; then
    pass "mutant $name fails the self-test"
  else
    fail "mutant $name failed for another reason: $out"
  fi
}
mutant exit1 \
  $'echo "refused: only the exact review commands in the system prompt may run" >&2\nexit 2' \
  $'echo "refused: only the exact review commands in the system prompt may run" >&2\nexit 1' \
  "the Bash guard let a stray command through"
mutant nopayload \
  '    [ "$cmd" = "$submit" ] || exit 0' \
  '    exit 0' \
  "the Bash guard let an APPROVE review through"
mutant dropcomments \
  'printf '\''%s\n'\'' "${READS[@]}" "$SUBMIT" "$COMMENTS" "$REPLY" > "$GUARD/allowed.txt"' \
  'printf '\''%s\n'\'' "${READS[@]}" "$SUBMIT" "$REPLY" > "$GUARD/allowed.txt"' \
  "the settings allow rules are not the guard's eight commands"

# The pin check, against a two-commit repo and a stub gh that answers from a fixture.
P=$ROOT/pin
mkdir -p "$P/repo" "$P/stub"
git -C "$P/repo" init -q
git -C "$P/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m A
A=$(git -C "$P/repo" rev-parse HEAD)
git -C "$P/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m B
B=$(git -C "$P/repo" rev-parse HEAD)
cat > "$P/stub/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *dismissals*) exit 0 ;; esac
f=""; while [ $# -gt 0 ]; do [ "$1" = --jq ] && f=$2; shift; done
jq -r "$f" "$REVIEWS_FIXTURE"
EOF
chmod +x "$P/stub/gh"
# name | review state | review commit_id | checkout | PIN | AFTER | expected rc | expected text
pincase() {
  local out rc=0
  printf '[{"id":1,"user":{"login":"claude[bot]"},"state":"%s","body":"review","commit_id":"%s"}]' "$2" "$3" > "$P/reviews.json"
  git -C "$P/repo" checkout -q "$4"
  out=$(cd "$P/repo" && PATH="$P/stub:$PATH" REVIEWS_FIXTURE="$P/reviews.json" GITHUB_REPOSITORY=o/r PR=1 \
    PIN=$5 AFTER=$6 DISMISS_TOKEN=x REVIEWER_RE='^claude\[bot\]$' HEAD_DIR="$P/repo" \
    bash "$ROOT/x/pincheck.sh" 2>&1) || rc=$?
  if [ "$rc" -eq "$7" ] && [[ "$out" == *"$8"* ]]; then pass "pin check: $1"; else fail "pin check: $1 (rc $rc): $out"; fi
}
pincase "matching commit passes" COMMENTED "$A" "$A" "$A" "$A" 0 "the review covered the pinned commit"
pincase "checkout at another commit" COMMENTED "$A" "$B" "$A" "$A" 1 "the review's checkout is at"
pincase "review filed on another commit" COMMENTED "$B" "$A" "$A" "$A" 1 "the latest review is filed on"
pincase "head moved during the review" COMMENTED "$A" "$A" "$A" "$B" 1 "the PR head moved"
pincase "an APPROVE review" APPROVED "$A" "$A" "$A" "$A" 1 "must only COMMENT"
pincase "no head read after the review" COMMENTED "$A" "$A" "$A" "" 1 "could not verify the pin"

[ "$fails" -eq 0 ] || { echo "::error::$fails self-test check(s) failed"; exit 1; }
echo "all self-test checks passed"
