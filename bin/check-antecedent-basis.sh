#!/usr/bin/env bash
set -euo pipefail

# check-antecedent-basis.sh — check a markdown blog post for antecedent basis violations
#
# Usage: bin/check-antecedent-basis.sh <file.md>
# Exit 0 if clean, exit 2 if violations found.

if [ $# -lt 1 ]; then
  echo "usage: bin/check-antecedent-basis.sh <file.md>" >&2
  exit 1
fi

file="$1"

if [ ! -f "$file" ]; then
  echo "error: file not found: $file" >&2
  exit 1
fi

# Extract description from YAML frontmatter
description=""
if head -1 "$file" | grep -q '^---'; then
  description=$(awk '/^---$/{if(++c==2)exit}c==1{print}' "$file" | grep -E '^\s*description:' | sed 's/^\s*description:\s*//' | sed 's/^["'"'"']\(.*\)["'"'"']$/\1/')
fi

# Strip YAML frontmatter to get body
body=$(awk '/^---$/{c++;next}c>=2' "$file")

# Build the full input (prompt + content) for claude
input="You are an antecedent basis checker for a blog post. The reader has zero prior context — they have not read any other posts on this site.

For each noun phrase, proper name, demonstrative reference (\"this change\", \"the module\", \"that approach\"), or piece of jargon in the text, verify that it has been introduced or defined before its first use. A term is \"introduced\" if the text explains what it is, links to a definition, or provides enough context for a reader with no prior knowledge of the project to understand the reference.

Acceptable introductions include:
- Explicit definitions (\"X is a Y that does Z\")
- Appositive descriptions (\"X, a memory module,\")
- Hyperlinks to external resources where the reader can learn what X is
- Context that makes the meaning clear without prior knowledge

Violations include:
- Demonstrative references with no antecedent (\"this change\" when no change has been named)
- Module names or project names used without explanation
- Jargon or acronyms used before being defined
- References to \"the previous post\" or similar without establishing what it covered

The description field (shown below between <description> tags) appears on an index page before the reader clicks through to the post — check it independently. Terms introduced in the post body do NOT count as antecedents for the description.

Output ONLY a list of violations, one per line, in the format:
line N: \"<phrase>\" has no antecedent

If there are no violations, output exactly: ok

<description>
${description}
</description>

<body>
${body}
</body>"

# Use env -u to strip CLAUDECODE from the child process environment,
# allowing nested claude invocation from within a Claude Code session
result=$(echo "$input" | env -u CLAUDECODE claude -p --model haiku 2>/dev/null) || {
  echo "error: claude command failed or timed out" >&2
  exit 1
}

if [ "$result" = "ok" ]; then
  exit 0
else
  echo "$result" >&2
  exit 2
fi
