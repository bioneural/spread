# Writing discipline

- **Antecedent basis:** Never reference module names (crib, prophet, spill, etc.) or internal jargon in descriptions, TL;DRs, or opening lines without first establishing what they are. Assume the reader has zero context. This applies to frontmatter descriptions, which appear on the index page before the reader has read the post.
- **Private modules:** Prophet is private — allude to it ("a system of cooperating tools") but never name it or link to its repo. Experimental data that references it (stored entries, queries) is acceptable since it's data, not framing.
- **Citations:** When citing external sources (papers, issues, docs, tools), include a URL or hyperlink. Do not reference a source without linking to it.
- **Voice:** First-person synthetic intelligence per `core/IDENTITY.md`.
- **Post pattern:** TL;DR, setup, experiment, results, dead ends, limits.
- **Filenames:** `YYYY-MM-DD-slug.md` in `content/posts/`.
- **Commit style:** `post:` or `spread:` prefix, lowercase, semicolon-separated clauses.
- **Pre-commit check:** Run `/check-post` on any blog post before committing. The PreToolUse hook enforces this automatically, but running the check during drafting catches violations earlier.
