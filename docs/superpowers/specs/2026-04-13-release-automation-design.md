# Release Automation Design

**Date:** 2026-04-13
**Status:** Approved

## Goal

Automate the full release pipeline so that `git tag vX.Y.Z && git push --tags` is the only manual step. The automation creates a GitHub release, updates the Homebrew formula, validates it, and merges — no human intervention needed after the tag push.

## Architecture

Two GitHub Actions workflows chained across two repos:

```
git tag v0.5.0 && git push --tags
        │
        ▼
┌─ macos-calendar-mcp ──────────────────────┐
│  .github/workflows/release.yml            │
│  Trigger: push tag matching v*             │
│                                            │
│  Steps:                                    │
│  1. Create GitHub release (auto-notes)     │
│  2. Download tarball, compute sha256       │
│  3. Open PR on homebrew-tap with updated   │
│     version, URL, and sha256 in formula    │
└────────────────────────────────────────────┘
        │ PR opened
        ▼
┌─ homebrew-tap ─────────────────────────────┐
│  .github/workflows/auto-merge-formula.yml  │
│  Trigger: pull_request (opened)            │
│                                            │
│  Steps:                                    │
│  1. Validate tarball URL returns HTTP 200  │
│  2. Download tarball, verify sha256 match  │
│  3. Auto-merge the PR                      │
└────────────────────────────────────────────┘
```

## Workflow 1: release.yml (macos-calendar-mcp)

**Trigger:** `on: push: tags: ['v*']`

**Steps:**

1. **Create GitHub release**
   - Uses `gh release create` with `--generate-notes` for auto-generated release notes from commits since the last tag.
   - Release title: the tag name (e.g., `v0.5.0`).

2. **Compute tarball sha256**
   - Download `https://github.com/miguelarios/macos-calendar-mcp/archive/refs/tags/{tag}.tar.gz`.
   - Compute sha256 with `shasum -a 256`.

3. **Open PR on homebrew-tap**
   - Clone `miguelarios/homebrew-tap`.
   - Update three lines in `Formula/macos-calendar-mcp.rb` using `sed`:
     - `url` — new tag tarball URL.
     - `sha256` — new hash.
     - `version` — new version string (tag without the `v` prefix).
   - Create a branch like `update-macos-calendar-mcp-0.5.0`.
   - Push and open PR with title like `macos-calendar-mcp 0.5.0`.

**Auth:** Requires a Personal Access Token (PAT) with `repo` scope, stored as a repository secret (`HOMEBREW_TAP_TOKEN`) on macos-calendar-mcp. The default `GITHUB_TOKEN` cannot create PRs on other repos.

## Workflow 2: auto-merge-formula.yml (homebrew-tap)

**Trigger:** `on: pull_request: types: [opened]`

**Validation steps (before merging):**

1. **Author check** — only process PRs from the expected PAT user (the GitHub account that owns the token).
2. **Tarball URL check** — extract the `url` from the formula, `curl --head` it, confirm HTTP 200.
3. **SHA256 check** — download the tarball, compute sha256, compare against the `sha256` value in the formula.

**Merge:** If all checks pass, auto-merge the PR using `gh pr merge --merge`.

**Auth:** The workflow needs write access to merge PRs. The default `GITHUB_TOKEN` is sufficient here since the workflow runs within the homebrew-tap repo. The workflow also needs `gh` CLI permissions — `permissions: contents: write, pull-requests: write`.

## Secrets Required

| Repo | Secret | Purpose |
|------|--------|---------|
| `macos-calendar-mcp` | `HOMEBREW_TAP_TOKEN` | PAT with `repo` scope for cross-repo PR creation |

## Formula Fields Updated

Three fields in `Formula/macos-calendar-mcp.rb`:

```ruby
url "https://github.com/miguelarios/macos-calendar-mcp/archive/refs/tags/v0.5.0.tar.gz"
sha256 "new_hash_here"
version "0.5.0"
```

## Edge Cases

- **Tarball not ready yet:** GitHub sometimes takes a moment to generate the tarball after a release is created. The release workflow should wait briefly (e.g., retry the download up to 3 times with a short delay) before computing the sha256.
- **Formula PR already open:** If a PR for a previous version is still open, the new PR is independent. The auto-merge workflow handles each PR on its own merits.
- **Tag deleted/recreated:** Not handled — don't do this. Tags should be immutable once pushed.

## What This Does NOT Cover

- Homebrew `brew audit` validation — overkill for a tap formula, and would require a macOS runner.
- Changelog generation beyond GitHub's auto-generated notes.
- Notification on failure — GitHub Actions already emails on workflow failure by default.
