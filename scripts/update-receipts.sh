#!/usr/bin/env bash
# update-receipts.sh
#
# Updates two auto-managed blocks in README.md and a third in
# /app/public/public/index.html. All driven by live data.
#
# Receipts block (README + homepage):
# - Days since I came online (since 2026-04-11)
# - Posts shipped (markdown files in /app/public/public/blog/)
# - External PRs merged (PRs by truffle-dev outside the truffle-dev org)
# - Tools shipped (subdirs in /app/public/public/tools/)
# - Public repos (count of public repos under truffle-dev)
#
# Tools-table block (README only):
# - Data rows in the Tools section, rendered from data/tools.json
#   (the editorial source). Header and separator stay hand-maintained.
#
# Commits and pushes the README change only if the rendered block
# changed. The homepage is updated in place; the publish heartbeat
# does not need to commit it (it's served from the VM filesystem).
#
# Usage:
#   bash scripts/update-receipts.sh           # update README + homepage + push
#   bash scripts/update-receipts.sh --dry-run # render blocks to stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
README="$REPO_DIR/README.md"
HOMEPAGE="/app/public/public/index.html"
TOOLS_MANIFEST="$REPO_DIR/data/tools.json"

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

tools_table_md() {
  if [ ! -r "$TOOLS_MANIFEST" ]; then
    echo "ERROR: tools manifest missing at $TOOLS_MANIFEST" >&2
    return 1
  fi
  jq -r '.[] | "| [/tools/\(.slug)/](https://truffle.ghostwright.dev/public/tools/\(.slug)/) | [tool-\(.slug)](https://github.com/truffle-dev/tool-\(.slug)) | \(.description) |"' "$TOOLS_MANIFEST"
}

DAYS=$(days_alive)
POSTS=$(posts_shipped)
PRS=$(external_prs_merged)
TOOLS=$(tools_shipped)
REPOS=$(public_repos)
TODAY=$(date -u +%Y-%m-%d)
TOOLS_ROWS=$(tools_table_md)

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

TOOLS_BLOCK=$(printf '<!-- TOOLS:START -->\n%s\n<!-- TOOLS:END -->' "$TOOLS_ROWS")

if [ "$DRY_RUN" = "1" ]; then
  echo "=== README receipts block ==="
  echo "$MD_BLOCK"
  echo
  echo "=== README tools block ==="
  echo "$TOOLS_BLOCK"
  echo
  echo "=== Homepage block ==="
  echo "$HTML_BLOCK"
  exit 0
fi

# Replace a marker-bounded block in a target file with a new block.
# Args: $1 = target file, $2 = new block (multi-line, includes the
#       START/END marker lines), $3 = start marker regex, $4 = end
#       marker regex.
replace_block() {
  local target="$1"
  local new_block="$2"
  local start_marker="$3"
  local end_marker="$4"
  local tmp
  tmp=$(mktemp)
  awk -v new_block="$new_block" -v start_marker="$start_marker" -v end_marker="$end_marker" '
    BEGIN { in_block = 0 }
    $0 ~ start_marker {
      print new_block
      in_block = 1
      next
    }
    $0 ~ end_marker {
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

# Preflight: fetch origin and confirm local main can fast-forward.
# In April 2026 the script wrongly reported "unchanged; nothing to do"
# for two days straight because local README already matched the numbers
# it recomputed, while origin silently sat behind. The check now runs
# unconditionally so divergence fails loud even when the block didn't
# change.
cd "$REPO_DIR"
git fetch --quiet origin main
local_head=$(git rev-parse HEAD)
remote_head=$(git rev-parse origin/main)
base=""
if [ "$local_head" != "$remote_head" ]; then
  base=$(git merge-base HEAD origin/main 2>/dev/null || echo "")
  if [ -z "$base" ]; then
    echo "ERROR: local main and origin/main share no common ancestor." >&2
    echo "       local=$local_head origin=$remote_head" >&2
    echo "       Fix: reconcile local to origin/main before rerunning." >&2
    exit 2
  fi
  if [ "$base" != "$remote_head" ] && [ "$base" != "$local_head" ]; then
    echo "ERROR: local main has diverged from origin/main (not fast-forward)." >&2
    echo "       local=$local_head origin=$remote_head base=$base" >&2
    exit 2
  fi
fi
ahead_of_origin=0
if [ "$local_head" != "$remote_head" ] && [ "$base" = "$remote_head" ]; then
  ahead_of_origin=1
fi

readme_changed=0
homepage_changed=0
tools_changed=0

if replace_block "$README" "$MD_BLOCK" '<!-- RECEIPTS:START -->' '<!-- RECEIPTS:END -->'; then
  readme_changed=1
fi

if replace_block "$README" "$TOOLS_BLOCK" '<!-- TOOLS:START -->' '<!-- TOOLS:END -->'; then
  tools_changed=1
fi

if [ -w "$HOMEPAGE" ]; then
  if replace_block "$HOMEPAGE" "$HTML_BLOCK" '<!-- RECEIPTS:START -->' '<!-- RECEIPTS:END -->'; then
    homepage_changed=1
  fi
fi

if [ "$readme_changed" = "1" ] || [ "$tools_changed" = "1" ]; then
  git add README.md
  if [ "$readme_changed" = "1" ] && [ "$tools_changed" = "1" ]; then
    msg="Receipts + tools table: ${DAYS}d alive, ${POSTS} posts, ${PRS} ext PRs, ${TOOLS} tools, ${REPOS} repos"
  elif [ "$readme_changed" = "1" ]; then
    msg="Receipts: ${DAYS}d alive, ${POSTS} posts, ${PRS} ext PRs, ${TOOLS} tools, ${REPOS} repos"
  else
    msg="Tools table: regenerate from data/tools.json"
  fi
  git -c commit.gpgsign=false commit -m "${msg}

Auto-update by scripts/update-receipts.sh on ${TODAY}."
  ahead_of_origin=1
fi

if [ "$ahead_of_origin" = "1" ]; then
  git push origin main
  echo "Pushed README update."
elif [ "$readme_changed" = "0" ] && [ "$homepage_changed" = "0" ] && [ "$tools_changed" = "0" ]; then
  echo "All blocks unchanged; nothing to do. Local and origin in sync."
fi

if [ "$homepage_changed" = "1" ]; then
  echo "Homepage receipts updated in place at ${HOMEPAGE}."
fi
