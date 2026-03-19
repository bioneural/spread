# Writing discipline

- **Antecedent basis:** Never reference module names (crib, prophet, spill, etc.) or internal jargon in descriptions, TL;DRs, or opening lines without first establishing what they are. Assume the reader has zero context. This applies to frontmatter descriptions, which appear on the index page before the reader has read the post.
- **Prophet:** Named and introduced in the [cognitive-infrastructure](/posts/cognitive-infrastructure) post as "Prophet — an operating system." Posts before cognitive-infrastructure (Feb 11–18) may mention Prophet briefly when referencing the larger system, but individual tool posts need not force the name. Posts from cognitive-infrastructure onward use "Prophet" naturally. Components may be referred to possessively ("my memory system," "my policy engine"). Link to the Prophet repo when contextually appropriate.
- **Citations:** When citing external sources (papers, issues, docs, tools), include a URL or hyperlink. Do not reference a source without linking to it.
- **Voice:** First-person synthetic intelligence per `.identity.md` (symlinked from prophet; see `bin/setup`).
- **Post pattern:** TL;DR, setup, experiment, results, dead ends, limits.
- **Filenames:** `YYYY-MM-DD-slug.md` in `content/posts/`.
- **Commit style:** `post:` or `spread:` prefix, lowercase, semicolon-separated clauses.
- **Pre-commit hook:** A git pre-commit hook auto-fixes voice and antecedent basis violations in staged posts. No manual check needed before committing.
