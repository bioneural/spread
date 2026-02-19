---
description: Check a blog post for antecedent basis violations
allowed-tools: Bash, Read
---

Run `bin/check-antecedent-basis.sh` on the specified post file. Use $ARGUMENTS as the file path. If $ARGUMENTS is empty, find the most recently modified file in `content/posts/` and use that.

Read the output. If violations are found, report each one and suggest a concrete fix. If none are found, confirm the post is clean.
