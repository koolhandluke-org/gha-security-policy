# GitHub Actions Security Policy

Org-wide policy for securing GitHub Actions against supply chain attacks.

## Why this exists

GitHub Actions are a prime target for supply chain attacks. Mutable tags like `v1` or `v1.2.3` can be force-pushed to point at malicious commits, silently compromising every workflow that references them.

Recent incidents:

- **[Trivy Action (March 2026)](https://www.aquasec.com/blog/trivy-github-action-supply-chain-attack/)** — Compromised via malicious tag update
- **[tj-actions/changed-files (March 2025)](https://www.stepsecurity.io/blog/harden-runner-detection-tj-actions-changed-files-attack)** — Secrets exfiltrated from 23,000+ repos

**SHA pinning eliminates this attack vector entirely.** A full 40-character commit SHA is immutable; it always resolves to the same code.

## Architecture

Two files work together to manage allowed SHAs across the org:

```
approved-actions.yml                allowlist.yml                    GitHub Org API
(latest SHAs)                       (all allowed SHAs)               (patterns_allowed)

Dependabot/Renovate  ──►  merge workflow appends    ──►  sync workflow pushes
updates uses: lines       new SHAs + removes              exact SHA patterns
                          expired entries
```

| File | Purpose | Managed by |
|------|---------|------------|
| `.github/workflows/approved-actions.yml` | One `uses:` line per action — always the latest version + SHA | Dependabot or Renovate |
| `allowlist.yml` | Accumulated list of all currently-allowed SHAs with `added` dates | merge-allowlist workflow |

The dummy workflow never runs (`if: false`). It exists so that Dependabot and Renovate can natively update the SHA pins — no custom regex managers needed.

This two-file model allows teams to migrate at their own pace. When a version is bumped, both the old and new SHAs remain allowed during the retention period.

## How it works

1. **Dependabot/Renovate** opens a PR updating `approved-actions.yml` (e.g. `checkout v4.2.2 → v4.2.3`)
2. A human reviews and merges the PR
3. **merge-allowlist** workflow triggers: appends the new SHA to `allowlist.yml` with today's date (the old SHA remains)
4. **sync-allowlist** workflow triggers: pushes all SHAs from `allowlist.yml` as exact `owner/repo@sha` patterns to the org API
5. Consumer repos merge their own Dependabot/Renovate PRs at their own pace
6. On schedule (monthly), the cleanup job removes entries older than `retention_days` that are no longer the current version

## Retention

Old SHAs are kept in `allowlist.yml` for the configured `retention_days` (default: 90 days). This gives teams time to merge their update PRs before the old SHA is removed from the org allowlist.

The cleanup job:
- **Always keeps** entries that match the current version in `approved-actions.yml`
- **Removes** entries older than `retention_days` that are not the current version
- **Reports** what was removed in the GitHub Actions job summary

To change the retention period, edit the `retention_days` field in `allowlist.yml`.

## How to request a new action

1. Check [`approved-actions.yml`](.github/workflows/approved-actions.yml) to see if the action is already approved
2. If not, [open an Action Request issue](../../issues/new?template=action-request.yml)
3. A security reviewer will evaluate the action and add it to the list

## How to adopt in your repo

### 1. Add the pinning check

Create `.github/workflows/security.yml` in your repo:

```yaml
name: Security
on: [pull_request]
jobs:
  enforce-pinning:
    uses: your-org/gha-security-policy/.github/workflows/enforce-pinning.yml@main
```

This blocks any PR that uses unpinned actions.

### 2. Set up automated SHA updates

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

### 3. Migrate existing actions to SHA pins

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

### Why two files instead of one?

A single file can't serve both purposes:
- Dependabot/Renovate needs exactly one `uses:` per action to track the latest version
- The org API needs every currently-allowed SHA (old + new) during the migration window

The two-file model keeps automation simple while allowing a grace period for teams to update.

### What happens if a team doesn't update in time?

After `retention_days`, the old SHA is removed from the org allowlist. Workflows using that SHA will fail with a permissions error. The team needs to merge their pending update PR (or manually update) to use the current SHA.

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
