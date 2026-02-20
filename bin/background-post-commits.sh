#!/usr/bin/env bash
set -euo pipefail

# background-post-commits.sh — hooker transform command
#
# Receives hook event JSON on stdin. If the commit involves blog posts,
# outputs a JSON patch that sets run_in_background: true. This forces
# post commits into background mode so the agent doesn't wait for the
# pre-commit quality hook.
#
# Used via: transform command: "bin/background-post-commits.sh"

input=$(cat)

# Check 1: posts already staged (from a prior git add)
staged_posts=$(git diff --cached --name-only 2>/dev/null | grep '^content/posts/.*\.md$' || true)

# Check 2: command references post files directly (chained git add && git commit)
if [ -z "$staged_posts" ]; then
  if echo "$input" | grep -q 'content/posts/.*\.md'; then
    staged_posts="command-reference"
  fi
fi

# Check 3: broad add (git add . / git add -A) with post files pending
if [ -z "$staged_posts" ]; then
  if echo "$input" | grep -qE 'git\s+add\s+(-A|--all|\.\b)'; then
    staged_posts=$(git status --porcelain 2>/dev/null | grep 'content/posts/.*\.md' || true)
  fi
fi

if [ -z "$staged_posts" ]; then
  exit 0
fi

# Output JSON patch — hooker merges this into tool_input
echo '{"run_in_background": true}'
