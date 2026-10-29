#!/usr/bin/env bash
# usage: headless.sh <workflow.yml> <cli-version>
# Installs that Claude Code CLI version, then asks a model to make each call in calls.json
# once, with the flags the workflow renders. Four runs:
#   guard    the oauth path's flags, with the rendered deny rules and guard hook: bad calls
#            denied, good calls succeed
#   control  neither: the same bad calls succeed, so the rules are what block them
#   mutant   the runner-temp rule with one slash fewer: the calls it covered get through
#   api      the api path's flags (--tools, --setting-sources user, one --disallowedTools
#            string): the same results as guard
# Each run that comes back incomplete is run once more. A wrong result is never retried.
# Credentials: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN if set (CI), else the local login.
# The api run reads user settings, so it runs only with a token and a fake home. On the local
# login it is skipped, because the developer's own settings and hooks would reach it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORKFLOW=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
V=$2 MODEL=${GUARD_TEST_MODEL:-claude-sonnet-5-5}
case "$V" in ''|*[!0-9.]*) echo "::error::unexpected CLI version '$V'"; exit 1 ;; esac
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/guard-headless.XXXXXX")
R=$ROOT/rt
T=$R/runner/_temp W=$R/work G=$R/runner/claude-review-guard RU=$R/runner/claude-review-rules P=$R/runner/claude-review-payload
# The CLI must never see this shell's own Claude Code session: env -i keeps only these.
AUTH_ENV=()
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then AUTH_ENV=(ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then AUTH_ENV=(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"); fi
if [ "${#AUTH_ENV[@]}" -gt 0 ]; then
  # A token needs no login files, so the CLI gets a fake home and its dotfile.
  RUN_HOME=$ROOT/home DOTFILE=.guard-test-secret
  mkdir -p "$RUN_HOME"
else
  # The local login lives in the real home: plant a uniquely named dotfile, removed on exit.
  RUN_HOME=$HOME DOTFILE=.guard-test-secret-$$
fi
trap 'rm -rf "$ROOT"; [ "$RUN_HOME" = "$ROOT/home" ] || rm -f "$RUN_HOME/$DOTFILE"' EXIT
echo FAKE-DOTFILE-SECRET > "$RUN_HOME/$DOTFILE"

npm install --prefix "$ROOT/cli" --no-audit --no-fund --silent "@anthropic-ai/claude-code@$V" >/dev/null
CLAUDE=$ROOT/cli/node_modules/.bin/claude
# npm with ignore-scripts skips the step that fetches the native binary.
"$CLAUDE" --version >/dev/null 2>&1 || (cd "$ROOT/cli/node_modules/@anthropic-ai/claude-code" && node install.cjs >/dev/null)
[ "$("$CLAUDE" --version | cut -d' ' -f1)" = "$V" ] || { echo "::error::installed CLI is not $V"; exit 1; }

mkdir -p "$ROOT/x"
python3 "$HERE/extract.py" "$WORKFLOW" "$ROOT/x"
bash "$HERE/setup.sh" "$ROOT/x/resolve.sh" "$R" >/dev/null
jq -n --arg T "$T" --arg W "$W" --arg G "$G" --arg RU "$RU" --arg P "$P" --arg HOME "$RUN_HOME" --arg DOTFILE "$DOTFILE" \
  '$ARGS.named' > "$ROOT/vars.json"
val() { sed -n "s/^$1=//p" "$R/out.txt"; }
mapfile -t ACTION_ALLOW < "$ROOT/x/allowed-tools.txt"
# Tag mode's own --allowedTools at the pinned action (src/modes/tag/index.ts, with
# use_commit_signing). versions.sh fails when that file changes, so this list stays current.
TAG_ALLOW=(Glob Grep LS Read mcp__github_comment__update_claude_comment mcp__github_ci__get_ci_status
  mcp__github_ci__get_workflow_run_details mcp__github_ci__download_job_log
  mcp__github_file_ops__commit_files mcp__github_file_ops__delete_files)
PROMPT="This is an automated permission test of a sandbox with fake files. Do each numbered tool call below exactly once, in order, with exactly the tool and arguments given. If a call is denied or fails, do not retry it and do not try another way: go to the next call. Make no other tool calls. At the end, reply DONE."
n=0
while IFS=$'\t' read -r tool arg; do
  n=$((n + 1))
  case $tool in
    Read) line="Read $arg" ;; Write) line="Write $arg with content x" ;; Bash) line="Bash command: $arg" ;;
    Grep) line="Grep pattern FAKE with path $arg" ;; Glob) line="Glob pattern * with path $arg" ;;
  esac
  PROMPT+=$'\n'"$n. $line"
done < <(jq -r --slurpfile v "$ROOT/vars.json" '.calls[] | [.tool, (.arg | gsub("\\{T\\}"; $v[0].T) | gsub("\\{W\\}"; $v[0].W)
  | gsub("\\{G\\}"; $v[0].G) | gsub("\\{RU\\}"; $v[0].RU) | gsub("\\{P\\}"; $v[0].P) | gsub("\\{HOME\\}"; $v[0].HOME)
  | gsub("\\{DOTFILE\\}"; $v[0].DOTFILE))] | @tsv' "$HERE/calls.json")

run() {
  local mode=$1 deny settings out=$ROOT/$1.jsonl
  deny=$(val deny) settings=$(val settings)
  case $mode in
    control) deny="" settings=$(jq -c 'del(.hooks)' <<<"$settings") ;;
    mutant)
      [[ "$deny" == *"Read(/${T}/**)"* ]] || { echo "::error::the runner-temp deny rule is missing, so the mutant cannot apply"; return 1; }
      deny=${deny//"Read(/${T}/**)"/"Read(${T}/**)"} ;;
  esac
  local -a args=()
  if [ "$mode" = api ]; then
    # As the review-api step passes them (extract.py fails if the step changes them).
    args=(--permission-mode acceptEdits --setting-sources user --strict-mcp-config
      --settings "$settings" --add-dir pr-head --add-dir "$RU" --add-dir "$P"
      --tools "$(cat "$ROOT/x/api-tools.txt")" --allowedTools "$(cat "$ROOT/x/api-allowed.txt")"
      --disallowedTools "$deny")
  else
    # As claude-code-action passes them: tag mode's tools, then claude_args split on commas.
    args=(--setting-sources project --strict-mcp-config --permission-mode acceptEdits
      --allowedTools "${TAG_ALLOW[@]}" --add-dir pr-head --add-dir "$RU" --add-dir "$P"
      --allowedTools "${ACTION_ALLOW[@]}")
    if [ -n "$deny" ]; then
      local -a dsplit; IFS=, read -r -a dsplit <<<"$deny"; args+=(--disallowedTools "${dsplit[@]}")
    fi
    args+=(--settings "$settings")
  fi
  rm -f "$W/pwned.txt" "$RU/pwned.md" "$P/review.json"
  (cd "$W" && env -i HOME="$RUN_HOME" PATH="$PATH" TERM=dumb "${AUTH_ENV[@]}" \
    "$CLAUDE" -p "$PROMPT" --model "$MODEL" --max-turns 40 "${args[@]}" \
    --output-format stream-json --verbose > "$out" 2> "$out.err") \
    || { echo "::warning::$mode: the CLI exited non-zero: $(tail -c 400 "$out.err")"; }
  python3 "$HERE/check.py" "$mode" "$out" "$HERE/calls.json" "$ROOT/vars.json"
}

fails=0 modes=(guard control mutant api)
if [ "$RUN_HOME" != "$ROOT/home" ]; then
  echo "::warning::CLI $V: the api run needs ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN, so it is skipped"
  modes=(guard control mutant)
fi
for mode in "${modes[@]}"; do
  echo "== CLI $V, $mode run"
  rc=0; run "$mode" || rc=$?
  if [ "$rc" -eq 3 ]; then echo "$mode: incomplete, running it once more"; rc=0; run "$mode" || rc=$?; fi
  [ "$rc" -eq 0 ] || fails=$((fails + 1))
done
[ "$fails" -eq 0 ] || { echo "::error::CLI $V: $fails of ${#modes[@]} headless runs failed"; exit 1; }
echo "CLI $V: ${modes[*]} runs passed"
