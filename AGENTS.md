# shared-workflows: agent guide

This repo holds reusable GitHub Actions workflows (`on: workflow_call`) for the
`schubydoo` repos. The first one is the `@claude review` workflow. Each project repo keeps
a short caller file that points at a workflow here, pinned to a full commit SHA. A change
to a shared job is one edit in this repo.

The repo is public, because a public repo can call a reusable workflow only from a public
repo. Never commit a secret, a host path, an IP address or a token.

## Lint

Run both linters on every workflow file you change:

- `uvx zizmor .github/workflows/<file>.yml` is the security audit.
- `actionlint .github/workflows/<file>.yml` checks the schema, the expressions and the
  embedded `run:` scripts.

Put `shellcheck` on `PATH` before you run `actionlint`. Without it, `actionlint` skips the
shell checks and does not warn you.

## Comment-triggered workflows

GitHub runs a workflow triggered by `issue_comment` from the default branch of the
calling repo. You cannot test a workflow change on its own PR. Test it locally first.
After the merge, test it on a throwaway PR. To test before a merge, point one caller's
`uses:` at a test branch of this repo.

## Branches and pull requests

- Every change is a PR against `main`. Never commit or push to `main`.
- Branch from a freshly fetched `origin/main`.
- Pin every action to a full commit SHA, with a version comment.
- In anything GitHub renders, `#7` becomes a link to issue or PR 7. For a plan step or a
  hardening change, write `step 3` or `change 7`.
- Commit as `Schuby <12485317+schubydoo@users.noreply.github.com>`. Never put a real name or
  a personal email in a commit, file or PR.

## Working rules

- Make sure that a claim is true before you report it. A status line in a doc is a cache.
  Read `git log`, the GitHub API or the code. If a run fails, show its output.
- Use `command grep` for a repo-wide search or a proof of absence. The `grep` shim in an
  agent shell skips gitignored files and does not warn you.
- Never widen a `gh` rule to a `:*` prefix, and never weaken a guard to make a test pass.
- Debug artifacts on a public repo stay downloadable by anyone for three days. Make sure that
  a debug run holds no secret before you share its link.
