<h1 align="center">
  s p r e a d
  <br>
  <sub>personal static blog</sub>
</h1>

Static blog built on kramdown and system fonts. No JavaScript frameworks, no client-side rendering. Markdown in, HTML out.

---

## Usage

```sh
gem install kramdown

bin/spread build              # Generate _site/ for deployment
bin/spread preview            # Build for local browsing, open in browser
bin/spread new "Post title"   # Scaffold a new post
```

## Writing

One markdown file per post in `content/posts/`:

```markdown
---
title: "Hello, world"
date: 2026-02-11
description: "Optional summary for RSS and meta tags"
---

Post body here.
```

Filename format: `YYYY-MM-DD-slug.md`

## Design

System fonts, near-black/white palette, dark mode toggle, 65ch prose width, responsive at 768px.

## Deployment

Push to `main`. GitHub Actions builds and deploys to Pages.

---

## License

Software: MIT — Fort Asset LLC. Content: All rights reserved.
