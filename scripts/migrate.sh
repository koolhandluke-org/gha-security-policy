#!/usr/bin/env bash
set -euo pipefail

# migrate.sh — Convert tagged GitHub Action references to SHA-pinned format.
#
# Usage: ./scripts/migrate.sh [directory]
#   directory: path to scan (default: .github/workflows)
#
# Requires: gh (GitHub CLI), authenticated

WORKFLOW_DIR="${1:-.github/workflows}"

if ! command -v gh &>/dev/null; then
  echo "Error: gh (GitHub CLI) is required. Install from https://cli.github.com/" >&2
  exit 1
fi

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "Error: Directory '$WORKFLOW_DIR' not found." >&2
  exit 1
fi

converted=0
skipped=0
failed=0

# Find all uses: lines with tagged references (not already SHA-pinned)
while IFS= read -r file; do
  echo "Scanning $file..."

  # Process each uses: line with a tag reference
  while IFS= read -r line; do
    # Extract the action reference (owner/repo@tag)
    ref=$(echo "$line" | grep -oP 'uses:\s*\K[^@]+@[^\s#]+' || true)
    [ -z "$ref" ] && continue

    action=$(echo "$ref" | cut -d@ -f1)
    tag=$(echo "$ref" | cut -d@ -f2)

    # Skip local actions
    [[ "$action" == ./* ]] && continue

    # Skip if already SHA-pinned (40-char hex)
    if [[ "$tag" =~ ^[a-f0-9]{40}$ ]]; then
      continue
    fi

    # Skip Docker references
    [[ "$action" == docker://* ]] && continue

    echo -n "  $action@$tag -> "

    # Resolve tag to SHA
    sha=$(gh api "repos/$action/git/ref/tags/$tag" --jq '.object.sha' 2>/dev/null || true)

    if [ -z "$sha" ]; then
      echo "FAILED (tag not found)"
      failed=$((failed + 1))
      continue
    fi

    # Check if it's an annotated tag (need to dereference)
    obj_type=$(gh api "repos/$action/git/ref/tags/$tag" --jq '.object.type' 2>/dev/null || true)
    if [ "$obj_type" = "tag" ]; then
      sha=$(gh api "repos/$action/git/tags/$sha" --jq '.object.sha' 2>/dev/null || true)
      if [ -z "$sha" ]; then
        echo "FAILED (could not dereference annotated tag)"
        failed=$((failed + 1))
        continue
      fi
    fi

    echo "$sha # $tag"

    # Replace in file: owner/repo@tag -> owner/repo@sha # tag
    # Handle cases with and without existing comments
    sed -i.bak "s|uses: ${action}@${tag}\( *#.*\)\?$|uses: ${action}@${sha} # ${tag}|" "$file"
    converted=$((converted + 1))

  done < <(grep -n 'uses:' "$file" 2>/dev/null || true)

done < <(find "$WORKFLOW_DIR" -name '*.yml' -o -name '*.yaml' | sort)

# Clean up backup files
find "$WORKFLOW_DIR" -name '*.bak' -delete 2>/dev/null || true

echo ""
echo "=== Migration Summary ==="
echo "Converted: $converted"
echo "Failed:    $failed"
echo ""

if [ "$failed" -gt 0 ]; then
  echo "Some tags could not be resolved. Check that the action/tag exists and you have gh auth."
  exit 1
fi

if [ "$converted" -eq 0 ]; then
  echo "All actions are already SHA-pinned."
else
  echo "Done. Review the changes with 'git diff' before committing."
fi
