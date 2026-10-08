import {
  BLOG_INDEX_PATH,
  blogPostPath,
  formatPostDate,
  getBlogBreadcrumb,
  POSTS,
  type BlogPost,
} from '../content/blog';
import {
  Breadcrumb,
  card,
  cardTitle,
  displayHeading,
  HelpCta,
  Section,
} from './Help';

export function PostCards({ posts = POSTS }: { posts?: BlogPost[] }) {
  return (
    <ul className="m-0 grid list-none grid-cols-2 gap-5 p-0 max-[620px]:grid-cols-[minmax(0,1fr)]">
      {posts.map((post) => (
        <li key={post.slug} className="flex">
          <a className={`${card} w-full`} href={blogPostPath(post.slug)}>
            <h3 className={cardTitle}>{post.title}</h3>
            <p className="mt-1.5 text-[15px] text-muted">{post.description}</p>
            <p className="mono mt-3 text-muted">
              <time dateTime={post.published}>
                {formatPostDate(post.published)}
              </time>
            </p>
          </a>
        </li>
      ))}
    </ul>
  );
}

export function BlogIndex() {
  return (
    <>
      <section
        className="flex max-w-[680px] flex-col gap-4 pt-10 pb-12 max-[620px]:pt-6"
        aria-labelledby="blog-h"
      >
        <span className="label">Blog</span>
        <h1
          id="blog-h"
          className={`text-[clamp(40px,6vw,72px)] leading-[0.96] ${displayHeading}`}
        >
          Keep what you learn.
        </h1>
        <p className="max-w-[34em] text-[19px] text-muted">
          Essays on writing things down, and making sure you see them again.
        </p>
      </section>
      <section className="border-t-[2.5px] border-ink py-12 max-[620px]:py-9">
        <h2 className="sr-only">All posts</h2>
        <PostCards />
      </section>
      <HelpCta />
    </>
  );
}

export function BlogPostView({ post }: { post: BlogPost }) {
  const date = post.updated ?? post.published;
  return (
    <>
      <article className="mx-auto max-w-[65ch] pt-6 pb-4">
        <Breadcrumb items={getBlogBreadcrumb(post)} />
        <header className="mt-8 flex flex-col gap-4">
          <h1
            className={`text-[clamp(34px,5vw,54px)] leading-[1] ${displayHeading}`}
          >
            {post.title}
          </h1>
          <p className="text-[19px] text-muted">{post.description}</p>
          <p className="mono text-muted">
            {post.updated ? 'Updated ' : ''}
            <time dateTime={date}>{formatPostDate(date)}</time>
          </p>
        </header>
        <div className="mt-2">
          {post.sections.map((section, i) => (
            <Section key={section.heading ?? i} section={section} />
          ))}
        </div>
        <a className="btn ghost mt-12" href={BLOG_INDEX_PATH}>
          More from the blog
        </a>
      </article>
      <HelpCta />
    </>
  );
}
