# GitHub Actions Security Policy

Org-wide framework for securing GitHub Actions against supply chain attacks through SHA pinning, automated version tracking, and centralized enforcement.

## The problem

GitHub Actions are a prime target for supply chain attacks. Mutable tags like `v1` or `v1.2.3` can be force-pushed to point at malicious commits, silently compromising every workflow that references them.

Every `uses:` line in a workflow is a trust decision. When a workflow references `actions/checkout@v4`, it trusts that the tag still points to the same code it did yesterday. That trust is misplaced — git tags are mutable. A repository owner (or an attacker with write access) can delete a tag, point it at a completely different commit, and force-push. No diff, no PR, no notification. The tag name hasn't changed. The version looks the same. But the code behind it is not.

This is not theoretical:

- **[tj-actions/changed-files (March 2025)](https://www.stepsecurity.io/blog/harden-runner-detection-tj-actions-changed-files-attack)** — An attacker gained access to the repo, modified the `v44` tag to point at a malicious commit that exfiltrated CI secrets (environment variables, `GITHUB_TOKEN`, any configured secrets). Over **23,000 repositories** were affected. The compromised code ran in CI pipelines across thousands of orgs before detection.
- **[reviewdog actions (March 2025)](https://github.com/reviewdog/reviewdog/issues/2079)** — Multiple reviewdog GitHub Actions were compromised via the same supply chain vector, leaking secrets from CI runners.
- **[Trivy Action (March 2026)](https://www.aquasec.com/blog/trivy-github-action-supply-chain-attack/)** — The widely-used container scanning action was compromised via a malicious tag update, injecting code into security scanning pipelines.

The pattern is always the same: attacker compromises an action repo, modifies a mutable tag, and every workflow that references it is instantly compromised.

### Why this is hard to solve manually

SHA pinning is the known fix. A full 40-character commit SHA (`actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`) is immutable and content-addressed — it always resolves to the exact same code. But pinning by hand creates new problems:

- **SHAs are opaque.** `@v4.2.2` is readable. `@11bd71901bbe5b163...` is not. Developers don't know what version they're on.
- **Updates are painful.** When a new version is released, someone has to look up the new SHA and update every workflow in every repo.
- **Org-wide enforcement is missing.** Even if one team pins correctly, another team can still reference `@v4` and re-introduce the attack surface.
- **Migration windows cause breakage.** If the org allowlist only permits the latest SHA, any repo that hasn't updated yet breaks immediately.

This repo solves all of these.

## The approach

A **two-file model** that separates version tracking from SHA accumulation, combined with GitHub's org-level action policies for enforcement.

```
approved-actions.yml                allowlist.yml                    GitHub Org API
(latest version + SHA)              (all allowed SHAs)               (patterns_allowed)

Dependabot/Renovate  ──►  merge, audit & sync workflow    ──►  GitHub Org API
updates uses: lines       appends new SHAs, removes              receives exact
                          expired, audits drift, syncs           SHA patterns
```

| File | Purpose | Managed by |
|------|---------|------------|
| `.github/workflows/approved-actions.yml` | One `uses:` line per action — always the latest version + SHA | Dependabot or Renovate |
| `allowlist.yml` | Accumulated list of all currently-allowed SHAs with `added` dates | merge-allowlist workflow |

### Why two files?

A single file can't serve both purposes:

- **Dependabot/Renovate** needs exactly one `uses:` per action to track the latest version. If you have multiple entries, it gets confused or creates conflicting PRs.
- **The org API** needs every currently-allowed SHA (old + new) so that teams running the previous version don't break while they migrate.

The two-file model keeps automation simple: Dependabot/Renovate operate on a standard workflow file with no custom configuration, while the allowlist accumulates SHAs and handles the migration window automatically.

### The dummy workflow trick

`approved-actions.yml` is a real workflow file, but it never runs (`if: false`). It exists purely so that Dependabot and Renovate can natively detect and update SHA-pinned actions — no custom regex managers, no scripts, no Renovate `matchManagers` configuration. Both tools already know how to update `uses:` lines in workflow files. This leverages that built-in capability.

## How it works

1. **Dependabot/Renovate** opens a PR updating `approved-actions.yml` when a new action version is released (e.g. `checkout v4.2.2 → v4.2.3`)
2. A **human reviews and merges** the PR — this is the trust decision point
3. The **merge, audit & sync** workflow triggers on push — four jobs run in sequence:
   - **Merge**: parses the new SHA from `approved-actions.yml` and appends it to `allowlist.yml` with today's date. The old SHA remains.
   - **Cleanup**: removes entries older than `retention_days` that are no longer the current version.
   - **Audit**: generates a read-only report showing stale entries and actions that are major versions behind.
   - **Sync**: pushes all SHAs from `allowlist.yml` as exact `owner/repo@sha` patterns to the GitHub org API (`/orgs/{ORG}/actions/permissions/selected-actions`)
4. Consumer repos merge their own Dependabot/Renovate PRs at their own pace — both old and new SHAs are allowed
5. On schedule (monthly), the cleanup, audit, and sync jobs run independently

## How this solves the problem

| Problem | How it's solved |
|---------|----------------|
| Mutable tags can be silently changed | Every action is referenced by immutable 40-char SHA — tag manipulation has no effect |
| SHAs are opaque and unreadable | Version comments (`# v4.2.2`) are preserved alongside every SHA for human readability |
| Updating SHAs is manual and error-prone | Dependabot/Renovate automatically open PRs with new SHAs when versions are released |
| No org-wide enforcement | The sync job pushes allowed SHAs to the GitHub org API — unapproved actions are blocked org-wide |
| Updating the allowlist breaks teams still on the old version | The two-file model with retention keeps old SHAs valid during the migration window |
| Developers can bypass pinning | The org-level action policy only allows approved SHA-pinned actions to run |
| No standard process for approving new actions | Issue template + security review workflow provides a clear request path |
| Initial migration is painful | `migrate.sh` script bulk-converts `owner/repo@tag` to `owner/repo@sha # tag` across all workflows |

## Settings

### Dependabot cooldown

Dependabot is configured with a cooldown period before opening PRs for new releases. This is a supply chain defense — if an attacker publishes a malicious version, the delay gives the community time to detect and yank it before it reaches your workflows.

```yaml
# .github/dependabot.yml
cooldown:
  default-days: 5        # wait 5 days before opening PRs
  semver-major-days: 7   # wait 7 days for major version bumps
```

Security updates (CVE advisories) bypass the cooldown and open immediately.

To change these values, edit [`.github/dependabot.yml`](.github/dependabot.yml).

### Retention

Old SHAs are kept in `allowlist.yml` for `retention_days` (default: **180 days**) before the cleanup job removes them. This is intentionally forgiving — the allowlist is not the place to force teams onto newer versions. That's Dependabot/Renovate's job.

The cleanup job:
- **Always keeps** entries that match the current version in `approved-actions.yml`
- **Removes** entries older than `retention_days` that are not the current version
- **Reports** what was removed in the GitHub Actions job summary

To change the retention period, edit `retention_days` in [`allowlist.yml`](allowlist.yml).

### Audit report

A monthly audit report runs alongside the cleanup job. It does not remove anything — it produces a read-only summary in the GitHub Actions job summary showing:

- **Actions with entries that are one or more major versions behind** the current approved version
- **All stale entries** (not the current version) with their age and the version they're on

Use this report to identify repos that may need attention, not to auto-enforce upgrades.

## Limitations

- **Requires GitHub org-level API access.** The sync workflow uses the `/orgs/{ORG}/actions/permissions/selected-actions` endpoint, which requires an `ORG_ADMIN_TOKEN` with `admin:org` scope. This is a privileged credential.
- **Does not protect against compromised code at the time of pinning.** SHA pinning guarantees immutability, not safety. If an action is already compromised when you pin it, you've pinned compromised code. The human review step on the Dependabot/Renovate PR is the trust boundary.
- **Auto-merging Dependabot PRs defeats the purpose.** If you auto-merge action update PRs without review, an attacker who publishes a malicious version as a new release will have it automatically rolled into your allowlist. Always review action updates.
- **Dependabot cannot pin unpinned actions.** Dependabot only updates existing SHA pins — it won't convert `@v4` to `@sha`. You must run the initial migration first (see `migrate.sh`), then Dependabot keeps them updated. Renovate can auto-pin.
- **Runner dependency on `yq`.** The merge and cleanup workflows use `yq` for YAML parsing. This is pre-installed on GitHub-hosted `ubuntu-latest` runners but may need to be installed on self-hosted runners.
- **The org API replaces the entire pattern list on each sync.** The sync job sends a PUT (not PATCH) to the org API. If another system also manages the `patterns_allowed` list, they will overwrite each other. This repo should be the single source of truth for allowed action patterns.
- **Docker-based actions are not covered.** Actions referenced as `docker://image:tag` are not tracked by this system. These are less common but have their own supply chain risks.
- **`github_owned_allowed: true` is a fallback.** The sync job sets this flag, which allows all `actions/*` actions regardless of pinning. This is a convenience trade-off — if you want strict enforcement even for official actions, set this to `false` and ensure every official action is in the allowlist.

## Dos and don'ts

### Do

- **Review every Dependabot/Renovate PR before merging.** Read the changelog, check for unexpected scope changes. This is the trust decision.
- **Run `migrate.sh` before enabling Dependabot.** Dependabot can't update what isn't pinned yet.
- **Keep the retention period generous.** 180 days is the default. Shorter periods cause unnecessary breakage for teams with slower merge cycles.
- **Use the issue template for new action requests.** This creates an auditable paper trail of what was approved, by whom, and why.
- **Enable "Require actions to be SHA-pinned" in the org settings.** This is a built-in GitHub setting under Actions → General that enforces pinning without needing a separate workflow.

### Don't

- **Don't auto-merge action update PRs.** This removes the human review step that prevents compromised versions from entering the allowlist.
- **Don't edit `allowlist.yml` by hand.** It's auto-managed by the merge workflow. Manual edits will be overwritten or cause merge conflicts.
- **Don't use this alongside other tools that manage `patterns_allowed` on the org API.** The sync job does a full PUT, not a PATCH. It will overwrite external changes.
- **Don't reduce `retention_days` below your slowest team's merge cadence.** If a team takes 120 days to merge Dependabot PRs, a 90-day retention will break their workflows.
- **Don't skip the initial migration.** Repos with unpinned actions (`@v4`) will not be tracked or updated by Dependabot. They remain vulnerable.

## How to request a new action

1. Check [`approved-actions.yml`](.github/workflows/approved-actions.yml) to see if the action is already approved
2. If not, [open an Action Request issue](../../issues/new?template=action-request.yml)
3. A security reviewer will evaluate the action and add it to the list

## How to adopt in your repo

### 1. Set up automated SHA updates

Pick **one** — Dependabot or Renovate.

#### Option A: Dependabot (recommended)

Copy [`.github/dependabot.yml`](.github/dependabot.yml) into your repo:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 5
      semver-major-days: 7
    groups:
      github-actions:
        patterns:
          - "*"
```

> **Note:** Dependabot does not auto-pin unpinned actions. You must pin them first (see step 3), then Dependabot keeps them updated.

#### Option B: Renovate

Add `renovate.json` to your repo:

```json
{
  "extends": ["local>your-org/gha-security-policy"]
}
```

This extends the shared config which will:
- Automatically pin any unpinned actions to their commit SHA
- Open PRs when new versions are released with updated SHAs
- Group all action updates into a single PR

### 2. Migrate existing actions to SHA pins

Run the migration script from this repo:

```bash
# Download the script
curl -sO https://raw.githubusercontent.com/your-org/gha-security-policy/main/scripts/migrate.sh
chmod +x migrate.sh

# Run against your workflows
./migrate.sh .github/workflows

# Review changes
git diff
```

The script:
- Scans all `.yml`/`.yaml` files in the given directory
- Resolves each `owner/repo@tag` to `owner/repo@sha # tag`
- Skips already-pinned actions and local composite actions (`./`)
- Prints a summary of what was converted

Requires `gh` (GitHub CLI) to be installed and authenticated.

## FAQ

### Why SHAs instead of tags?

Tags are mutable. A repo owner (or attacker with push access) can delete and recreate a tag pointing at different code. SHAs are immutable and content-addressed — they always resolve to the exact same code.

### What happens if a team doesn't update in time?

After `retention_days` (default: 180 days), the old SHA is removed from the org allowlist. Workflows using that SHA will fail with a permissions error. The team needs to merge their pending update PR (or manually update) to use the current SHA. The monthly audit report flags these entries before they expire so teams have advance warning.

### Does this break Dependabot/Renovate updates?

No. Both understand SHA-pinned actions and will open PRs with updated SHAs when new versions are released. The version comment (e.g. `# v4.2.2`) tells them which version the SHA corresponds to.

### What about actions from `actions/*` (GitHub official)?

Even official actions should be SHA-pinned. The org API is configured with `github_owned_allowed: true` as a fallback, but pinning provides consistent security posture.

### What about local/composite actions (`./`)?

Local actions are part of your repo and covered by your normal code review process. The pinning check allows these by default.

### How do I find the SHA for a specific version?

```bash
gh api repos/OWNER/REPO/git/ref/tags/VERSION --jq '.object.sha'
```

If the response shows `type: "tag"` (annotated tag), dereference it:

```bash
gh api repos/OWNER/REPO/git/tags/SHA --jq '.object.sha'
```
