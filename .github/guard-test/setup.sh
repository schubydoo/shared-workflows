#!/usr/bin/env bash
# usage: setup.sh <resolve.sh> <root>
# Runs the resolve step (and so its guard self-test) in a fake runner layout under <root>,
# then plants the fake secrets and the PR-tree symlinks that headless.sh probes.
# ⚠️ The resolve step runs `sudo` to write /etc/claude-code. A stub sudo first on PATH
# rewrites that path into <root>: the local Claude Code reads /etc/claude-code too, and the
# guard would then block a developer's own shell.
set -euo pipefail
RESOLVE=$1 R=$2
T=$R/runner/_temp W=$R/work G=$R/runner/claude-review-guard RU=$R/runner/claude-review-rules
mkdir -p "$T" "$W/pr-head/.git" "$W/.git" "$RU" "$R/stub" "$R/etc-claude-code"
# Quoted heredoc: the stub reads its target from the environment, so <root> needs no escaping.
cat > "$R/stub/sudo" <<'EOF'
#!/usr/bin/env bash
args=(); for a in "$@"; do args+=("${a//\/etc\/claude-code/$GUARD_TEST_ETC}"); done
exec "${args[@]}"
EOF
chmod +x "$R/stub/sudo"
: > "$R/out.txt"
(cd "$W" && PATH="$R/stub:$PATH" GUARD_TEST_ETC="$R/etc-claude-code" \
  RUNNER_TEMP="$T" GITHUB_WORKSPACE="$W" GITHUB_REPOSITORY=testowner/testrepo \
  GITHUB_OUTPUT="$R/out.txt" COMMENT_PR=1 COMMENT_BODY='@claude review' \
  REVIEW_OUTPUT_STYLE='' AUTH=oauth REVIEW_PLUGIN_PATH=claude-review-plugin REVIEW_APP_SLUG='' \
  bash "$RESOLVE")
[ -s "$R/etc-claude-code/managed-settings.json" ] \
  || { echo "::error::the resolve step wrote no managed settings into the stub folder"; exit 1; }
echo FAKE-RUNNER-SECRET > "$T/secret.txt"
printf '[remote "origin"]\n\turl = https://x-access-token:FAKE-WS-TOKEN@github.com/testowner/testrepo\n' > "$W/.git/config"
printf '[remote "origin"]\n\turl = https://x-access-token:FAKE-PRHEAD-TOKEN@github.com/testowner/testrepo\n' > "$W/pr-head/.git/config"
echo '# Test project README (harmless)' > "$W/pr-head/README.md"
echo 'Rules: review carefully.' > "$RU/rules.md"
ln -sfn "$T/secret.txt" "$W/pr-head/link-temp"
ln -sfn ../.git/config "$W/pr-head/link-git"
ln -sfn "$G/allowed.txt" "$W/pr-head/link-guard"
ln -sfn "$T" "$W/pr-head/link-dir"
