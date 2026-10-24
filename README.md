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

Put this in the project repo as `.github/workflows/claude-review.yml`. Replace `<sha>` with a
full commit SHA of this repo, and replace the secret names with the repo's own names.

```yaml
name: Claude review

on:
  # The review is requested by a comment, so this trigger is required. The hardening lives
  # in the called workflow: an exact-command allow list, a guard hook, and a pin to the head SHA.
  issue_comment: # zizmor: ignore[dangerous-triggers]
    types: [created]

permissions: {}

jobs:
  review:
    # A called workflow cannot hold more permissions than the caller grants, so grant the
    # full list here.
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
      actions: read
    uses: schubydoo/shared-workflows/.github/workflows/claude-review.yml@<sha> # <version>
    with:
      output-style: simple-english:simple-english
    secrets:
      app-client-id: ${{ secrets.EXAMPLE_CI_CLIENT_ID }}
      app-private-key: ${{ secrets.EXAMPLE_CI_APP_PRIVATE_KEY }}
      claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Do not add a `concurrency:` group named `claude-review-<number>` to the caller. The called job
already uses that name, and the two runs then wait on each other.

The repo also needs `.github/claude-review-instructions.md` on its default branch. The job reads
that file from the default branch, so a pull request cannot change the rules for its own review.
The job refuses a file shorter than 500 bytes.

That file holds only the project rules: what to look for, the severities, how to classify an
earlier finding on a re-review, and project links. Do not put posting rules in it. The workflow
writes a central posting recipe next to it. The recipe covers the grouped review, the
`review.json` shape, thread replies, the tally line and the allowed commands. Where the two files
disagree about posting, the recipe wins, because the guard enforces it. The recipe is the
`claude-review-recipe.md` heredoc in the "Fetch the review instructions" step.

### Inputs

| Input | Default | Use |
| --- | --- | --- |
| `auth` | `oauth` | The billing path. `api` is not built yet, and the job refuses it. |
| `model` | `claude-opus-5` | The `--model` value: one model ID or alias. |
| `timeout-minutes` | `30` | The job timeout. |
| `runs-on` | `ubuntu-latest` | The runner label. |
| `exclude-comments-by-actor` | `greptile-apps[bot],codecov[bot]` | Logins whose comments stay out of Claude's context. |
| `output-style` | empty | A Simple English output style, for example `simple-english:simple-english`. Empty means no plugin. |

### Secrets

| Secret | Required | Use |
| --- | --- | --- |
| `app-client-id` | yes | The client ID of the calling repo's CI GitHub App. |
| `app-private-key` | yes | The private key of that App. |
| `claude-oauth-token` | for `auth: oauth` | The repo's `CLAUDE_CODE_OAUTH_TOKEN`. |

The CI App token is read-only and scoped to the calling repo. The workflow's own steps use it to
read the PR, its comments and the instructions file. The review itself posts as `claude[bot]`
through the Claude GitHub App.

### Testing a change

GitHub runs an `issue_comment` workflow from the caller's default branch. A pull request in this
repo therefore cannot run its own version. To test a change before it merges:

1. Push the change to a test branch of this repo.
2. In one low-traffic project repo, point the caller's `uses:` at that branch. The caller
   change takes effect only after it merges into that repo's default branch.
3. Comment `@claude review debug` on a throwaway pull request there.

## Linting

The `Lint` workflow runs `actionlint` and `zizmor` on every pull request. To run them locally:

```bash
actionlint
uvx zizmor .
```

Put `shellcheck` on `PATH` first. Without it, `actionlint` skips the shell checks and does not
warn you.
