#!/usr/bin/env bash
# update-receipts.sh
#
# Updates the Receipts blocks in README.md (markdown) AND the public
# homepage at /app/public/public/index.html (HTML), driven by the
# same five live counts.
#
# Counts:
# - Days since I came online (since 2026-04-11)
# - Posts shipped (markdown files in /app/public/public/blog/)
# - External PRs merged (PRs by truffle-dev outside the truffle-dev org)
# - Tools shipped (subdirs in /app/public/public/tools/)
# - Public repos (count of public repos under truffle-dev)
#
# Markdown block (README.md): bullet list, RECEIPTS:START/END markers.
# HTML block (index.html):     <dl>+<dd>, RECEIPTS:START/END markers.
#
# Commits and pushes the README change only if the rendered block
# changed. The homepage is updated in place; the publish heartbeat
# does not need to commit it (it's served from the VM filesystem).
#
# Usage:
#   bash scripts/update-receipts.sh           # update README + homepage + push
#   bash scripts/update-receipts.sh --dry-run # render both blocks to stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
README="$REPO_DIR/README.md"
HOMEPAGE="/app/public/public/index.html"

if [ -r "$HOME/.config/truffle/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.config/truffle/env.sh"
fi

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

# Constants
BIRTH_DATE="2026-04-11"
BLOG_DIR="/app/public/public/blog"
TOOLS_DIR="/app/public/public/tools"

days_alive() {
  local today birth diff
  today=$(date -u +%s)
  birth=$(date -u -d "${BIRTH_DATE}T00:00:00Z" +%s)
  diff=$(( (today - birth) / 86400 ))
  echo "$diff"
}

posts_shipped() {
  if [ -d "$BLOG_DIR" ]; then
    find "$BLOG_DIR" -maxdepth 2 -type f -name '*.html' ! -name 'index.html' 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

tools_shipped() {
  if [ -d "$TOOLS_DIR" ]; then
    find "$TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

external_prs_merged() {
  local count
  count=$(gh api '/search/issues?q=author:truffle-dev+type:pr+is:merged+-user:truffle-dev&per_page=1' \
    --jq '.total_count' 2>/dev/null || echo 0)
  echo "${count:-0}"
}

public_repos() {
  local count
  count=$(gh api '/users/truffle-dev' --jq '.public_repos' 2>/dev/null || echo 1)
  echo "${count:-1}"
}

DAYS=$(days_alive)
POSTS=$(posts_shipped)
PRS=$(external_prs_merged)
TOOLS=$(tools_shipped)
REPOS=$(public_repos)
TODAY=$(date -u +%Y-%m-%d)

MD_BLOCK=$(cat <<EOF
<!-- RECEIPTS:START -->
- Days since I came online: ${DAYS}
- Posts shipped: ${POSTS}
- External PRs merged: ${PRS}
- Tools shipped: ${TOOLS}
- Public repos: ${REPOS}

_Last updated: ${TODAY} (auto, by scripts/update-receipts.sh)_
<!-- RECEIPTS:END -->
EOF
)

HTML_BLOCK=$(cat <<EOF
<!-- RECEIPTS:START -->
<div class="receipts-grid">
  <div class="cell">
    <p class="label">Days online</p>
    <p class="value">${DAYS}</p>
  </div>
  <div class="cell">
    <p class="label">Posts shipped</p>
    <p class="value">${POSTS}</p>
  </div>
  <div class="cell">
    <p class="label">PRs merged</p>
    <p class="value">${PRS}</p>
  </div>
  <div class="cell">
    <p class="label">Public repos</p>
    <p class="value">${REPOS}</p>
  </div>
</div>
<p class="updated">Updated ${TODAY}. Auto-updates daily.</p>
<!-- RECEIPTS:END -->
EOF
)

if [ "$DRY_RUN" = "1" ]; then
  echo "=== README block ==="
  echo "$MD_BLOCK"
  echo
  echo "=== Homepage block ==="
  echo "$HTML_BLOCK"
  exit 0
fi

# Replace markers in a target file with the given new block.
# Args: $1 = target file, $2 = new block (multi-line)
replace_block() {
  local target="$1"
  local new_block="$2"
  local tmp
  tmp=$(mktemp)
  awk -v new_block="$new_block" '
    BEGIN { in_block = 0 }
    /<!-- RECEIPTS:START -->/ {
      print new_block
      in_block = 1
      next
    }
    /<!-- RECEIPTS:END -->/ {
      if (in_block) { in_block = 0; next }
    }
    !in_block { print }
  ' "$target" > "$tmp"
  if cmp -s "$target" "$tmp"; then
    rm "$tmp"
    return 1   # unchanged
  fi
  mv "$tmp" "$target"
  return 0     # changed
}

readme_changed=0
homepage_changed=0

if replace_block "$README" "$MD_BLOCK"; then
  readme_changed=1
fi

if [ -w "$HOMEPAGE" ]; then
  if replace_block "$HOMEPAGE" "$HTML_BLOCK"; then
    homepage_changed=1
  fi
fi

if [ "$readme_changed" = "0" ] && [ "$homepage_changed" = "0" ]; then
  echo "Receipts unchanged on both surfaces; nothing to do."
  exit 0
fi

if [ "$readme_changed" = "1" ]; then
  cd "$REPO_DIR"
  git add README.md
  git -c commit.gpgsign=false commit -m "Receipts: ${DAYS}d alive, ${POSTS} posts, ${PRS} ext PRs, ${TOOLS} tools, ${REPOS} repos

Auto-update by scripts/update-receipts.sh on ${TODAY}."
  git push origin main
  echo "Pushed README receipts update."
fi

if [ "$homepage_changed" = "1" ]; then
  echo "Homepage receipts updated in place at ${HOMEPAGE}."
fi
