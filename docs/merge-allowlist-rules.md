# Merge Allowlist Rules

How the merge-allowlist workflow operates, what each setting controls, and the tradeoffs behind every configurable decision.

---

## How it works today

The system uses a **two-file model**:

| File | Purpose | Who edits it |
|------|---------|-------------|
| `approved-actions.yml` | One `uses:` line per action, always the **latest** approved SHA. Dependabot/Renovate open PRs against this file. | Dependabot PRs (human-reviewed). |
| `allowlist.yml` | **Accumulated** list of all allowed SHAs (current + old versions within retention window). | Automation only (merge job). |

A four-job pipeline runs on every merge to `approved-actions.yml` and on a monthly schedule:

```
merge → cleanup → audit → sync
```

1. **Merge** — Reads `approved-actions.yml`, appends any new SHA+version to `allowlist.yml` with today's date. Idempotent.
2. **Cleanup** — Removes entries older than `retention_days` unless they are still the current version.
3. **Audit** — Generates a read-only report flagging stale entries and major-version gaps.
4. **Sync** — PUTs the full `allowlist.yml` to the GitHub org API as `patterns_allowed`, replacing whatever was there.

---

## Configurable settings and their tradeoffs

### 1. Retention period (`retention_days`)

**Where:** `allowlist.yml` line 5
**Current value:** `180` (6 months)

This controls how long old SHAs remain in the org allowlist after a newer version is approved. Teams referencing the old SHA keep working until the entry expires.

| Option | Effect | Risk |
|--------|--------|------|
| **Shorter (e.g. 30-60 days)** | Old versions expire fast. Forces teams to update quickly. Smaller allowlist. | Teams that merge Dependabot PRs slowly will break without warning. Emergency rollback to an old version may not be possible. |
| **Current (180 days)** | 6-month migration window. Generous for most orgs. | Allowlist grows larger. A compromised SHA stays allowed for up to 6 months even after a newer version replaces it. |
| **Longer (e.g. 365 days)** | Maximum flexibility for slow-moving teams. | A known-bad SHA stays in the org allowlist for a full year. Defeats the purpose of rapid revocation. |
| **No cleanup (remove the job)** | Allowlist only grows, never shrinks. | Unbounded list of old SHAs. Any historically-approved version works forever. |

**Decision question:** How fast can teams in the org realistically merge Dependabot PRs? If the answer is "weeks, not months", 90 days is likely safe. If some teams go months without touching CI, 180 is the conservative default.

---

### 2. Dependabot cooldown

**Where:** `.github/dependabot.yml`
**Current values:** `default-days: 5`, `semver-major-days: 7`

The cooldown delays Dependabot from opening PRs for newly-published action versions. This is a supply chain defense: if an attacker publishes a malicious release, the community has a window to detect and yank it before your org tries to adopt it.

| Option | Effect | Risk |
|--------|--------|------|
| **No cooldown (0 days)** | Fastest adoption. New versions surface immediately. | If a malicious version is published (like tj-actions/changed-files March 2025), it arrives in a PR before anyone notices. |
| **Short cooldown (3-5 days)** | Balances speed and safety. Most attacks are detected within 48h. | Slightly delayed adoption. Narrow window for slower-discovered compromises. |
| **Long cooldown (14-30 days)** | Maximum caution. Virtually all supply chain attacks are public knowledge by then. | Significant delay in getting legitimate security patches. You're running known-vulnerable versions longer. |

Security-advisory updates (CVEs) bypass the cooldown regardless of setting.

**Decision question:** How much do you trust the upstream action maintainers? For well-known actions (`actions/*`), cooldown is less critical since GitHub controls them. For third-party actions, longer cooldowns provide more protection.

---

### 3. `github_owned_allowed`

**Where:** Sync job, hardcoded in the API payload
**Current value:** `true`

Controls whether all `actions/*` (GitHub-owned) actions are automatically allowed regardless of the allowlist.

| Option | Effect | Risk |
|--------|--------|------|
| **`true` (current)** | Any `actions/*` action works even if not in `allowlist.yml`. Convenient. | GitHub-owned actions are still mutable-tag-vulnerable in theory, though the risk is lower since GitHub controls them. A compromised GitHub infrastructure could push a bad `actions/*` version. |
| **`false`** | Every action — including `actions/checkout` — must be explicitly SHA-pinned and listed. Full control. | Significantly more maintenance. Every GitHub-owned action version must go through the approval flow. Missing one breaks builds across the org. |

**Decision question:** Is your threat model "protect against compromised third-party maintainers" (keep `true`) or "protect against any supply chain vector including GitHub itself" (set `false`)? Most orgs choose `true` as a pragmatic tradeoff.

---

### 4. `verified_allowed`

**Where:** Sync job, hardcoded in the API payload
**Current value:** `false`

Controls whether actions from GitHub Marketplace "verified creators" are automatically allowed.

| Option | Effect | Risk |
|--------|--------|------|
| **`false` (current)** | Only explicitly allowlisted actions work. Tight control. | More review overhead. Every new third-party action needs a request + PR. |
| **`true`** | Any verified-creator action works without being in the allowlist. | "Verified" only means the creator's identity is confirmed, not that their code is audited. A verified creator can still be compromised (or go rogue). Effectively bypasses the entire allowlist for a large set of actions. |

**Decision question:** Do you trust GitHub's verification process enough to auto-allow verified creators? This is a significant loosening of control. Most security-conscious orgs keep this `false`.

---

### 5. Update cadence (Dependabot schedule)

**Where:** `.github/dependabot.yml`
**Current value:** `interval: "weekly"`

| Option | Effect | Risk |
|--------|--------|------|
| **Daily** | Catch new versions faster. More PRs to review. | PR fatigue. Reviewers may start rubber-stamping. |
| **Weekly (current)** | Balanced cadence. Manageable PR volume. | Up to 7 days before a new version is detected (plus cooldown). |
| **Monthly** | Minimal PR noise. | Up to 30 days running an outdated version. Combined with cooldown, total lag could be 5+ weeks. |

**Decision question:** How many action updates does the org typically see per week? If the answer is 1-3, weekly is fine. If 10+, consider grouping (already enabled via the `groups` config).

---

### 6. Dependabot vs. Renovate

**Where:** `.github/dependabot.yml` vs `.github/renovate.json` (both present in repo)

| Aspect | Dependabot | Renovate |
|--------|-----------|----------|
| **Auto-pinning** | Cannot convert `@v4` → `@sha`. Requires running `migrate.sh` first. | Auto-pins unpinned references before opening PRs. |
| **Cooldown** | Native `cooldown` config (used here). | Requires `stabilityDays` setting. |
| **Grouping** | Groups via `groups` config. | Groups via `packageRules`. |
| **Hosting** | GitHub-native. Zero setup. | Self-hosted or Mend-hosted. More config. |
| **Custom managers** | No custom regex managers needed — natively understands `uses:`. | Same — natively understands `uses:`. |

**Decision question:** If all repos in the org already use SHA-pinned references, Dependabot is simpler. If you need to migrate repos that still use `@v4` tags, Renovate handles the initial pin automatically.

You should pick one. Running both creates duplicate PRs and confusion.

---

### 7. Audit schedule

**Where:** `merge-allowlist.yml` cron schedule
**Current value:** Monthly (1st of every month, 06:00 UTC)

The audit job generates a report in the GitHub Actions job summary. It flags entries that are major versions behind and lists all stale entries.

| Option | Effect | Risk |
|--------|--------|------|
| **Weekly** | Catch stale entries sooner. | More noise if nothing changes week-to-week. |
| **Monthly (current)** | Low noise. Gives teams time to act on findings. | A stale entry could sit for up to a month before being flagged. |
| **On every push** | Already happens (audit runs after every merge). The schedule is additive. | No additional risk, but the monthly run catches drift even when no new PRs are merged. |

The audit is read-only — it never modifies anything. Increasing frequency has no operational risk.

---

### 8. Sync mechanism (PUT vs. incremental)

**Where:** Sync job in `merge-allowlist.yml`
**Current behavior:** Full PUT replacement

The sync job sends a `PUT` to `/orgs/{ORG}/actions/permissions/selected-actions`, which **replaces** the entire `patterns_allowed` list. This means `allowlist.yml` must be the single source of truth.

| Option | Effect | Risk |
|--------|--------|------|
| **Full PUT (current)** | Simple, deterministic. Whatever is in the file is what's enforced. No drift. | If another tool or person manually adds patterns via the API, the next sync overwrites them. |
| **Incremental (PATCH-style, not currently implemented)** | Could merge with manually-added patterns. | Drift between the file and the API. Harder to audit. "What's actually allowed?" becomes ambiguous. |

**Decision question:** Is this repo the only thing managing `patterns_allowed`? If yes, full PUT is correct. If other teams need to add patterns outside this flow, you'd need a more complex merge strategy (not recommended — it defeats the single-source-of-truth model).

---

### 9. Emergency revocation

Not currently implemented as a dedicated workflow. Today, revoking a compromised action requires:

1. Remove the entry from `allowlist.yml` manually
2. Remove or update the line in `approved-actions.yml`
3. Push to main
4. Wait for the sync job to PUT the updated list

| Option | Effort | Speed |
|--------|--------|-------|
| **Manual edit + push (current)** | Low. Edit two files, push. | Minutes. Depends on someone being available. |
| **Dedicated revoke workflow** | Medium. Build a `workflow_dispatch` that takes an action name, removes it from both files, and syncs immediately. | Seconds. Any org admin can trigger it. |
| **Direct API call** | None. `gh api --method PUT` with the updated list. | Immediate, but creates drift between the API and the file. Next sync re-adds the revoked action. |

**Decision question:** How fast does the org need to respond to a supply chain incident? If the answer is "sub-minute," a dedicated revoke workflow or runbook is worth building.

---

### 10. Token management (`ORG_ADMIN_TOKEN`)

**Where:** Repository secret
**Current setup:** PAT with `admin:org` scope

| Option | Effect | Risk |
|--------|--------|------|
| **Personal Access Token (current)** | Simple to set up. Tied to a person's account. | If the person leaves or their account is compromised, the token must be rotated. Token has broad `admin:org` scope. |
| **GitHub App installation token** | Scoped to specific permissions. Not tied to a person. | More setup (register app, install on org, generate tokens). Worth it for production. |
| **OIDC + fine-grained PAT** | Short-lived tokens. Minimal blast radius. | Most complex setup. Requires OIDC provider config and fine-grained PAT beta features. |

**Decision question:** Is this a personal org or a company org? For company orgs, a GitHub App is the standard recommendation. For personal/small orgs, a PAT is fine.

---

## Summary: decision matrix

| Setting | Conservative | Balanced (current) | Permissive |
|---------|-------------|-------------------|------------|
| `retention_days` | 90 | 180 | 365 |
| Cooldown (default) | 14 days | 5 days | 0 days |
| Cooldown (major) | 30 days | 7 days | 0 days |
| `github_owned_allowed` | `false` | `true` | `true` |
| `verified_allowed` | `false` | `false` | `true` |
| Update cadence | Monthly | Weekly | Daily |
| Token type | GitHub App + OIDC | GitHub App | PAT |
| Revocation | Dedicated workflow | Manual edit | Direct API |
