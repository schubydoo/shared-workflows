#!/usr/bin/env bash
# usage: versions.sh <workflow.yml> <package.json>
# Prints each Claude Code CLI version the review pins, one per line: the one that the pinned
# claude-code-action installs, and the api path's own pin. Fails if the action's tag-mode
# tool list file changed: a tool the action adds by itself is not covered by the deny list.
set -euo pipefail
WORKFLOW=$1 PACKAGE=$2
# sha256 of src/modes/tag/index.ts at claude-code-action v1.0.264 (unchanged since v1.0.262).
# If this fails, read that file's tagModeTools at the new pin, cover any new tool in the
# deny list and in headless.sh, then record the new hash here.
TAG_MODE_SHA256=7e732570534be83ff96526bc6e578d2dbd9b4b33dcb0768e685e171a518b2556
mapfile -t shas < <(sed -n 's/.*uses: anthropics\/claude-code-action@\([0-9a-f]\{40\}\).*/\1/p' "$WORKFLOW")
[ "${#shas[@]}" -eq 1 ] || { echo "::error::expected one claude-code-action pin in $WORKFLOW, found ${#shas[@]}" >&2; exit 1; }
raw="https://raw.githubusercontent.com/anthropics/claude-code-action/${shas[0]}"
v_run=$(curl -fsSL "$raw/src/entrypoints/run.ts" | sed -n 's/.*const claudeCodeVersion = "\([0-9.]*\)".*/\1/p')
v_base=$(curl -fsSL "$raw/base-action/action.yml" | sed -n 's/.*CLAUDE_CODE_VERSION="\([0-9.]*\)".*/\1/p')
if [ -z "$v_run" ] || [ "$v_run" != "$v_base" ]; then
  echo "::error::the action at ${shas[0]} names CLI '$v_run' in run.ts and '$v_base' in base-action" >&2; exit 1
fi
tag=$(curl -fsSL "$raw/src/modes/tag/index.ts" | sha256sum | cut -d' ' -f1)
[ "$tag" = "$TAG_MODE_SHA256" ] \
  || { echo "::error::src/modes/tag/index.ts changed at ${shas[0]}: read its tool list, then update TAG_MODE_SHA256 in versions.sh" >&2; exit 1; }
v_api=$(jq -r '.dependencies["@anthropic-ai/claude-code"]' "$PACKAGE")
case "$v_api" in ''|*[!0-9.]*) echo "::error::unexpected api path CLI pin '$v_api'" >&2; exit 1 ;; esac
printf '%s\n' "$v_run" "$v_api" | sort -u
