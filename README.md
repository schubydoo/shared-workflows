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
| `auth` | `oauth` | The billing path: `oauth` or `api`. See "The two billing paths". |
| `anthropic-federation-rule-id` | empty | `auth: api` only. The federation rule ID (`fdrl_...`). |
| `anthropic-organization-id` | empty | `auth: api` only. The Anthropic organization ID. |
| `anthropic-service-account-id` | empty | `auth: api` only. The service account ID (`svac_...`). |
| `anthropic-workspace-id` | empty | `auth: api` only. The workspace ID (`wrkspc_...`). Usage bills to it. |
| `timeout-minutes` | `30` | The job timeout. |
| `runs-on` | `ubuntu-latest` | The runner label. |
| `exclude-comments-by-actor` | `greptile-apps[bot],codecov[bot]` | Logins whose comments stay out of Claude's context. |
| `output-style` | empty | A Simple English output style, for example `simple-english:simple-english`. Empty means no plugin. |

The model is not an input. Every review runs `claude-opus-5-5`, set once as `REVIEW_MODEL` in
the workflow, so no repo can override it. A caller that still passes `model:` fails.

### Secrets

| Secret | Required | Use |
| --- | --- | --- |
| `app-client-id` | yes | The client ID of the calling repo's CI GitHub App. |
| `app-private-key` | yes | The private key of that App. |
| `claude-oauth-token` | for `auth: oauth` | The repo's `CLAUDE_CODE_OAUTH_TOKEN`. Never used on `auth: api`. |

Every CI App token is scoped to the calling repo. The workflow's own steps use a read-only one to
read the PR, its comments and the instructions file.

### The two billing paths

`auth: oauth` runs `claude-code-action` on the repo's `CLAUDE_CODE_OAUTH_TOKEN`. Anthropic counts
it as Claude Code usage, on the subscription. The review posts as `claude[bot]`.

`auth: api` runs `claude -p` from a workflow step, with Claude Code pinned by
`.github/claude-review/package-lock.json`. Anthropic counts it as Agent SDK usage, which the
plan's monthly API credits cover. The job signs in with Workload Identity Federation, so no Claude
credential is stored. The review posts as the repo's CI App, and workflow steps keep a progress
comment on the PR. The CI App needs Pull requests write and Issues write on this path.

The caller for `auth: api` adds these lines under `with:`. The secrets stay the same, and
`claude-oauth-token` can stay for a switch back to `oauth`.

```yaml
      auth: api
      anthropic-federation-rule-id: ${{ vars.ANTHROPIC_FEDERATION_RULE_ID }}
      anthropic-organization-id: ${{ vars.ANTHROPIC_ORG_ID }}
      anthropic-service-account-id: ${{ vars.ANTHROPIC_SERVICE_ACCOUNT_ID }}
      anthropic-workspace-id: ${{ vars.ANTHROPIC_WORKSPACE_ID }}
```

The four values are identifiers, not credentials, so they are repo variables.

### The federation rule for each repo

Each repo has its own rule in the Claude Console, with its own workspace, so usage stays split
per repo. Create it with the GitHub Actions tile of Connect workload. Then make its match block
look like this, with the repo's values:

```json
{
  "subject_prefix": "repo:schubydoo/<repo>:ref:refs/heads/main",
  "audience": "https://api.anthropic.com",
  "claims": {
    "repository": "schubydoo/<repo>",
    "repository_owner": "schubydoo",
    "event_name": "issue_comment",
    "ref": "refs/heads/main",
    "actor": "schubydoo",
    "workflow_ref": "schubydoo/<repo>/.github/workflows/claude-review.yml@refs/heads/main"
  },
  "condition": "claims.repository_id == \"<repo id>\" && claims.repository_owner_id == \"<owner id>\" && claims.job_workflow_ref.startsWith(\"schubydoo/shared-workflows/.github/workflows/claude-review.yml@\")"
}
```

- `workflow_ref` names the caller file on `main`. A comment-triggered run always uses that copy,
  so a pull request cannot change it.
- `job_workflow_ref` names this repo's workflow. The prefix match accepts any ref, because each
  Renovate bump changes the pinned SHA. The caller file on `main` decides which SHA runs.
- The IDs pin the repo and the owner, so a renamed or recreated repo with the same name does not
  match. Get them with `gh api repos/schubydoo/<repo> --jq '.id, .owner.id'`.
- The `jti` replay check stays on. The job writes a fresh GitHub OIDC token every 4 minutes.

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
