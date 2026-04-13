# Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate the full release pipeline so `git tag vX.Y.Z && git push --tags` creates a GitHub release and updates the Homebrew formula with no manual steps.

**Architecture:** Two GitHub Actions workflows across two repos. Workflow 1 (macos-calendar-mcp) triggers on tag push, creates a release, and opens a PR on homebrew-tap. Workflow 2 (homebrew-tap) validates the PR and auto-merges it.

**Tech Stack:** GitHub Actions, `gh` CLI, shell scripting, `sed`

---

## File Structure

**macos-calendar-mcp repo:**
- Create: `.github/workflows/release.yml` — release + homebrew PR workflow

**homebrew-tap repo (miguelarios/homebrew-tap):**
- Create: `.github/workflows/auto-merge-formula.yml` — validate and auto-merge formula PRs

---

### Task 1: Create release workflow (macos-calendar-mcp)

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the workflow file**

```yaml
name: Release and Update Homebrew

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${{ github.ref_name }}" \
            --title "${{ github.ref_name }}" \
            --generate-notes

      - name: Compute tarball sha256
        id: sha
        run: |
          TAG="${{ github.ref_name }}"
          URL="https://github.com/miguelarios/macos-calendar-mcp/archive/refs/tags/${TAG}.tar.gz"

          # Retry up to 3 times — GitHub may not have the tarball ready immediately
          for i in 1 2 3; do
            HTTP_CODE=$(curl -sL -o tarball.tar.gz -w "%{http_code}" "$URL")
            if [ "$HTTP_CODE" = "200" ]; then
              break
            fi
            echo "Attempt $i: got HTTP $HTTP_CODE, retrying in 10s..."
            sleep 10
          done

          if [ "$HTTP_CODE" != "200" ]; then
            echo "::error::Failed to download tarball after 3 attempts (HTTP $HTTP_CODE)"
            exit 1
          fi

          SHA=$(shasum -a 256 tarball.tar.gz | awk '{print $1}')
          echo "sha256=$SHA" >> "$GITHUB_OUTPUT"
          echo "Tarball sha256: $SHA"

      - name: Open PR on homebrew-tap
        env:
          GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
        run: |
          TAG="${{ github.ref_name }}"
          VERSION="${TAG#v}"
          SHA="${{ steps.sha.outputs.sha256 }}"
          BRANCH="update-macos-calendar-mcp-${VERSION}"

          git clone "https://x-access-token:${GH_TOKEN}@github.com/miguelarios/homebrew-tap.git" tap
          cd tap

          git checkout -b "$BRANCH"

          FORMULA="Formula/macos-calendar-mcp.rb"
          sed -i "s|url \".*\"|url \"https://github.com/miguelarios/macos-calendar-mcp/archive/refs/tags/${TAG}.tar.gz\"|" "$FORMULA"
          sed -i "s|sha256 \".*\"|sha256 \"${SHA}\"|" "$FORMULA"
          sed -i "s|version \".*\"|version \"${VERSION}\"|" "$FORMULA"

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add "$FORMULA"
          git commit -m "macos-calendar-mcp ${VERSION}"
          git push origin "$BRANCH"

          gh pr create \
            --repo miguelarios/homebrew-tap \
            --base main \
            --head "$BRANCH" \
            --title "macos-calendar-mcp ${VERSION}" \
            --body "Automated formula update for [v${VERSION}](https://github.com/miguelarios/macos-calendar-mcp/releases/tag/${TAG})."
```

- [ ] **Step 2: Verify the file parses correctly**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"`
Expected: No errors (exits silently).

If `pyyaml` isn't available, use: `ruby -ryaml -e "YAML.load_file('.github/workflows/release.yml')"`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow for automated GitHub releases and Homebrew updates"
```

---

### Task 2: Create auto-merge workflow (homebrew-tap)

**Files:**
- Create: `.github/workflows/auto-merge-formula.yml` (in miguelarios/homebrew-tap)

- [ ] **Step 1: Clone homebrew-tap locally**

```bash
gh repo clone miguelarios/homebrew-tap /tmp/homebrew-tap
cd /tmp/homebrew-tap
```

- [ ] **Step 2: Create the workflow file**

Create `.github/workflows/auto-merge-formula.yml`:

```yaml
name: Auto-merge Formula Update

on:
  pull_request:
    types: [opened]

jobs:
  validate-and-merge:
    runs-on: ubuntu-latest
    if: github.actor == 'miguelarios'
    permissions:
      contents: write
      pull-requests: write
    steps:
      - name: Checkout PR branch
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.ref }}

      - name: Extract formula fields
        id: formula
        run: |
          FORMULA="Formula/macos-calendar-mcp.rb"
          URL=$(grep -oP 'url "\K[^"]+' "$FORMULA")
          SHA=$(grep -oP 'sha256 "\K[^"]+' "$FORMULA")
          echo "url=$URL" >> "$GITHUB_OUTPUT"
          echo "sha256=$SHA" >> "$GITHUB_OUTPUT"
          echo "Formula URL: $URL"
          echo "Formula sha256: $SHA"

      - name: Validate tarball URL
        run: |
          HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "${{ steps.formula.outputs.url }}")
          if [ "$HTTP_CODE" != "200" ]; then
            echo "::error::Tarball URL returned HTTP $HTTP_CODE"
            exit 1
          fi
          echo "Tarball URL is valid (HTTP 200)"

      - name: Validate sha256
        run: |
          curl -sL -o tarball.tar.gz "${{ steps.formula.outputs.url }}"
          ACTUAL=$(shasum -a 256 tarball.tar.gz | awk '{print $1}')
          EXPECTED="${{ steps.formula.outputs.sha256 }}"
          if [ "$ACTUAL" != "$EXPECTED" ]; then
            echo "::error::SHA256 mismatch: expected $EXPECTED, got $ACTUAL"
            exit 1
          fi
          echo "SHA256 verified: $ACTUAL"

      - name: Auto-merge PR
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh pr merge "${{ github.event.pull_request.number }}" \
            --repo miguelarios/homebrew-tap \
            --merge \
            --delete-branch
```

- [ ] **Step 3: Verify the file parses correctly**

Run: `ruby -ryaml -e "YAML.load_file('.github/workflows/auto-merge-formula.yml')"`
Expected: No errors.

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/auto-merge-formula.yml
git commit -m "ci: add auto-merge workflow for formula update PRs"
git push origin main
```

---

### Task 3: Configure PAT secret on macos-calendar-mcp

This task requires manual action by the repo owner.

- [ ] **Step 1: Create a Personal Access Token**

Go to https://github.com/settings/tokens and create a fine-grained PAT (or classic PAT) with `repo` scope. The token must belong to `miguelarios` (the author check in the homebrew-tap workflow uses `github.actor == 'miguelarios'`).

- [ ] **Step 2: Add the secret to macos-calendar-mcp**

```bash
gh secret set HOMEBREW_TAP_TOKEN --repo miguelarios/macos-calendar-mcp
```

Paste the PAT when prompted.

- [ ] **Step 3: Verify the secret exists**

```bash
gh secret list --repo miguelarios/macos-calendar-mcp
```

Expected: `HOMEBREW_TAP_TOKEN` appears in the list.

---

### Task 4: Push workflows and test end-to-end

- [ ] **Step 1: Push the release workflow to macos-calendar-mcp**

```bash
cd /Users/mrios/Documents/macos-calendar-mcp
git push origin main
```

- [ ] **Step 2: Create a test tag and push it**

```bash
git tag v0.5.0
git push origin v0.5.0
```

- [ ] **Step 3: Verify the release was created**

```bash
gh run list --repo miguelarios/macos-calendar-mcp --limit 1
gh release view v0.5.0 --repo miguelarios/macos-calendar-mcp
```

Expected: Workflow run shows as completed. Release exists with auto-generated notes.

- [ ] **Step 4: Verify the homebrew-tap PR was opened**

```bash
gh pr list --repo miguelarios/homebrew-tap
```

Expected: A PR titled "macos-calendar-mcp 0.5.0" is open.

- [ ] **Step 5: Verify the homebrew-tap PR was auto-merged**

Wait ~1 minute for the auto-merge workflow to run, then:

```bash
gh pr list --repo miguelarios/homebrew-tap --state merged --limit 1
```

Expected: The PR is merged and the branch is deleted.

- [ ] **Step 6: Verify the formula is correct**

```bash
gh api repos/miguelarios/homebrew-tap/contents/Formula/macos-calendar-mcp.rb \
  --jq '.content' | base64 -d | grep -E 'url|sha256|version'
```

Expected: Shows v0.5.0 URL, correct sha256, and version "0.5.0".
