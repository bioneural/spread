#!/usr/bin/env bash
set -euo pipefail

# background-post-commits.sh — hooker transform command
#
# Receives hook event JSON on stdin. If staged files include blog posts,
# outputs a JSON patch that sets run_in_background: true. This forces
# post commits into background mode so the agent doesn't wait for the
# pre-commit quality hook.
#
# Used via: transform command: "bin/background-post-commits.sh"

# Check if staged files include blog posts
staged_posts=$(git diff --cached --name-only 2>/dev/null | grep '^content/posts/.*\.md$' || true)

if [ -z "$staged_posts" ]; then
  exit 0
fi

# Output JSON patch — hooker merges this into tool_input
echo '{"run_in_background": true}'
