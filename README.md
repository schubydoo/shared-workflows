# shared-workflows

Reusable GitHub Actions workflows for the `schubydoo` repos. Each project repo keeps a short
caller file. A change to a shared job is one edit in this repo.

## `claude-review.yml`

An on-demand pull request review by Claude. The repository owner starts it with an
`@claude review` comment on a pull request. Add `debug` (`@claude review debug`) to also upload
the raw execution log as an artifact for three days. Anyone can download that artifact on a
public repo.

The review is advisory. It posts one grouped COMMENT review with inline comments, and it never
approves or requests changes.

### Caller file

Every repo uses this file as `.github/workflows/claude-review.yml`, unchanged except for `<sha>`
and the two App secret names. All settings live in this repo, so a caller passes no inputs.

```yaml
name: Claude review

# On-demand PR review: comment "@claude review" on a pull request.
# The job and all its settings live in schubydoo/shared-workflows. This file only calls it.

on:
  # A comment starts the review, so this trigger is required.
  issue_comment: # zizmor: ignore[dangerous-triggers]
    types: [created]

permissions: {}

jobs:
  review:
    # A called workflow gets no more permissions than the caller grants.
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
      actions: read
    uses: schubydoo/shared-workflows/.github/workflows/claude-review.yml@<sha> # main
    secrets:
      app-client-id: ${{ secrets.EXAMPLE_CI_CLIENT_ID }}
      app-private-key: ${{ secrets.EXAMPLE_CI_APP_PRIVATE_KEY }}
      # For the oauth path and the fallback from api.
      claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Do not add a `concurrency:` group named `claude-review-<number>` to the caller. The called job
already uses that name, and the two runs then wait on each other.

### What the repo provides

- `.github/claude-review-instructions.md` on the default branch: the project rules (what to look
  for, severities, re-review classification, link format). The job refuses a file under 500 bytes.
  Posting rules do not belong there. The workflow writes a central posting recipe next to it, and
  the recipe wins on posting.
- Two secrets for the repo's CI GitHub App: its client ID and private key. The App needs Contents
  read, Pull requests read and write, and Issues read and write.
- Four repo variables, read by the workflow itself: `ANTHROPIC_FEDERATION_RULE_ID`,
  `ANTHROPIC_ORG_ID`, `ANTHROPIC_SERVICE_ACCOUNT_ID` and `ANTHROPIC_WORKSPACE_ID`. They are
  identifiers, not credentials. A called workflow reads the caller's variables.
- A federation rule in the Claude Console (see below).

### Fixed settings

Every review uses the same settings, set in the workflow:

| Setting | Value |
| --- | --- |
| Model | `claude-opus-5-5` (`REVIEW_MODEL`) |
| Output style | `simple-english:simple-english` (the plugin is pinned by SHA) |
| Timeout | 30 minutes |
| Runner | `ubuntu-latest` |
| Comments kept out of Claude's context | `greptile-apps[bot]`, `codecov[bot]` |

The workflow has no inputs. The caller passes only its secrets.

### The two billing paths

`api` (the default) runs `claude -p` from a workflow step, with Claude Code pinned by
`.github/claude-review/package-lock.json`. Anthropic counts it as Agent SDK usage, which the
plan's API credits cover. It signs in with Workload Identity Federation, so no Claude credential
is stored. The review posts as the repo's CI App, with a progress comment.

`oauth` runs `claude-code-action` on `CLAUDE_CODE_OAUTH_TOKEN`. Anthropic counts it as Claude
Code usage, on the subscription. The review posts as `claude[bot]`.

The repo variable `CLAUDE_REVIEW_AUTH` picks the path, with no commit. When the variable is
unset, the path is `api`.

```bash
gh variable set CLAUDE_REVIEW_AUTH -R schubydoo/<repo> --body oauth   # use the subscription
gh variable delete CLAUDE_REVIEW_AUTH -R schubydoo/<repo>             # back to api
```

### Automatic fallback

The `api` path can fall back on its own. If the API refuses the run for billing, for example
with "Credit balance is too low", the same job runs the review again on the `oauth` path. Two
conditions must hold: the `api` attempt posted no review, and the repo has
`CLAUDE_CODE_OAUTH_TOKEN`. Any other failure fails the job, so a review is never paid for or posted
twice. If a review fell back, the progress comment says so. Once the credits are gone for good,
set `CLAUDE_REVIEW_AUTH` to `oauth` to skip the failing first attempt.

To test the fallback without spending the credits, set the repo variable
`CLAUDE_REVIEW_TEST_FALLBACK` to `true`. The job then skips the `api` attempt and falls back.
Delete the variable after the test.

### The federation rule for each repo

Each repo has its own rule, service account and workspace in the Claude Console, so usage stays
split per repo. Create the rule with Connect workload and the `github-actions` issuer, scope
`workspace:developer`, token lifetime 600 seconds. Its match block:

- Subject pattern: `repo:schubydoo/<repo>:ref:refs/heads/main`. If the repo has GitHub's
  immutable subject turned on, it is `repo:schubydoo@<owner id>/<repo>@<repo id>:ref:refs/heads/main`
  instead. `gh api repos/schubydoo/<repo>/actions/oidc/customization/sub` shows which.
- Audience: `https://api.anthropic.com`
- Claims: `repository` = `schubydoo/<repo>`, `repository_owner` = `schubydoo`, `event_name` =
  `issue_comment`, `ref` = `refs/heads/main`, `actor` = `schubydoo`, `actor_id` = `<owner id>`,
  `workflow_ref` = `schubydoo/<repo>/.github/workflows/claude-review.yml@refs/heads/main`.
- Condition:

```text
claims.repository_id == "<repo id>" && claims.repository_owner_id == "<owner id>" && claims.job_workflow_ref.startsWith("schubydoo/shared-workflows/.github/workflows/claude-review.yml@")
```

`gh api repos/schubydoo/<repo> --jq '.id, .owner.id'` gives the two IDs. The `job_workflow_ref`
prefix accepts any commit of this workflow, so Renovate's pin bumps keep working. The Console's
edit form cannot add a condition to a rule without one, so create rules with the wizard.

### Testing a change

GitHub runs an `issue_comment` workflow from the caller's default branch. A pull request in this
repo therefore cannot run its own version. To test a change before it merges:

1. Push the change to a test branch of this repo.
2. In one low-traffic project repo, point the caller's `uses:` at that branch. The caller
   change takes effect only after it merges into that repo's default branch.
3. Comment `@claude review debug` on a throwaway pull request there.

## Guard test

The `Guard test` workflow tests the review's guard on each pull request. A guard is the set of
deny rules and the Bash hook that limit what Claude can read, write and run. The workflow has
two jobs.

The `guard self-test` job needs no model and no secret, and it runs on every pull request:

- It runs the resolve step with its own guard self-test.
- It breaks the guard in three ways, and each broken copy must fail that self-test.
- It runs the pin check on a matching commit and on five kinds of drift.
- It reads the CLI version that each pin installs. If the action's tag-mode tool list
  changed, it fails, because a tool that the action adds by itself is not in the deny list.

The `guard headless` job has work only on some pull requests: those that change
`claude-review.yml`, the CLI pin in `.github/claude-review/`, or the test itself. On other pull
requests, it passes at once. On each pinned CLI version, a model makes each
call in `.github/guard-test/calls.json` once, in three runs:

- `guard`: the rendered rules. Each bad call is denied, and each good call succeeds.
- `control`: no deny rules and no hook. The bad calls succeed, so the rules are what block.
- `mutant`: one rule with a slash missing. The calls that it covered get through.

A run that skips a call or makes an unlisted call runs once more. If it is still incomplete,
the job fails. A wrong result fails at once. The job needs the `GUARD_TEST_ANTHROPIC_API_KEY`
secret. If that secret is empty, the job fails. Each CLI version costs about $0.15.

To run the tests locally, install PyYAML, then run these commands from the repo root:

```bash
bash .github/guard-test/selftest.sh .github/workflows/claude-review.yml
bash .github/guard-test/versions.sh .github/workflows/claude-review.yml .github/claude-review/package.json
bash .github/guard-test/headless.sh .github/workflows/claude-review.yml <cli-version>
```

For credentials, `headless.sh` uses the `ANTHROPIC_API_KEY` variable. Without that variable,
the script uses your local Claude Code login. The
scripts work in a new temporary folder. A stub `sudo` keeps the resolve step out of
`/etc/claude-code`, because your own Claude Code reads that folder too. The CLI runs under
`env -i` with `--setting-sources project --strict-mcp-config`, so your own settings do not
reach it.

## Linting

The `Lint` workflow runs `actionlint` and `zizmor` on every pull request. To run them locally:

```bash
actionlint
uvx zizmor .
```

Put `shellcheck` on `PATH` first. Without it, `actionlint` skips the shell checks and does not
warn you.
