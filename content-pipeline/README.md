# Content pipeline

Drafts and ideas for content before it ships. Nothing here is published: a piece goes live only when it's moved into the site (`site-landing/src/content/`) and deployed.

## Blog (`blog/`)

The blog is SEO content for people new to the app (see the blog rule in `CLAUDE.md`). We publish slowly, roughly one post every few days at most, so each one gets checked properly.

- `blog/ideas.md` is the backlog: one line per topic, with the search phrase it targets.
- Each post in progress gets its own file, `blog/<slug>.md`, with a status at the top:
  - **outline:** structure, sources to check, what to leave out.
  - **draft:** full text, citations not yet checked against the originals.
  - **ready:** facts checked and reading level fine; next step is adding it to `site-landing/src/content/blog.ts`.
- After a post is published, delete its file here. `blog.ts` is the source of truth from then on, and the post's history is in git.

Before a post moves to **ready**:

- Check every historical and research claim against the original source, not a summary of it.
- Mention the app lightly, and only for features the shipped app has.
- Keep it to grade 7 (`pnpm test` enforces this once it's in `blog.ts`).
- Link to related help articles and earlier posts, and add links back from them where it makes sense.

## Free tools (`free-tools/`)

Printables and other free things people can download, link to and share, such as templates. Same idea as the blog: useful on their own, with the app mentioned lightly. `free-tools/ideas.md` is the backlog. Where they'll live on the site (a `/free` or `/tools` page, PDFs or web pages) isn't decided yet.
