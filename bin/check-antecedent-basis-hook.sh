#!/usr/bin/env bash
set -euo pipefail

# check-antecedent-basis-hook.sh — PreToolUse hook for Claude Code
#
# Reads hook JSON from stdin. If the Bash command contains "git commit"
# and staged files include blog posts, runs the antecedent basis checker
# on each. Blocks the commit if violations are found.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read hook input from stdin
input=$(cat)

# Extract the command from tool_input.command
command=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null) || exit 0

# Only check git commit commands
if ! echo "$command" | grep -q 'git commit'; then
  exit 0
fi

# Find staged blog post files
staged_posts=$(git diff --cached --name-only 2>/dev/null | grep '^content/posts/.*\.md$' || true)

if [ -z "$staged_posts" ]; then
  exit 0
fi

# Check each staged post
violations_found=0
while IFS= read -r post; do
  if [ -f "$post" ]; then
    if ! "$SCRIPT_DIR/check-antecedent-basis.sh" "$post" 2>&1; then
      violations_found=1
    fi
  fi
done <<< "$staged_posts"

if [ "$violations_found" -eq 1 ]; then
  echo "Antecedent basis violations found in staged blog posts. Fix them before committing." >&2
  exit 2
fi

exit 0
