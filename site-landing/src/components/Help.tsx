import type { ReactNode } from 'react';
import {
  getArticlesInCategory,
  getHelpBreadcrumb,
  getRelatedArticles,
  HELP_CATEGORIES,
  helpArticlePath,
  HELP_INDEX_PATH,
  parseInline,
  type HelpArticle,
  type HelpSection,
} from '../content/help';
import { Nav } from './Hero';
import { Footer } from './Sections';
import { AppStoreButton, Sprites } from './shared';

const displayHeading =
  "font-black tracking-[-0.03em] [font-variation-settings:'wdth'_110]";
const card =
  'stk block min-w-0 p-5 no-underline transition-[transform,box-shadow] duration-150 hover:-translate-px hover:shadow-sticker-lg active:translate-[2px] active:shadow-none';
const cardTitle =
  "text-[20px] leading-tight font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]";

export function HelpShell({ children }: { children: ReactNode }) {
  return (
    <>
      <Sprites />
      <div className="mx-auto max-w-[1140px]">
        <Nav base="/" learnCurrent />
        <main>{children}</main>
        <Footer base="/" />
      </div>
    </>
  );
}

function Inline({ text }: { text: string }) {
  return parseInline(text).map((token, i) => {
    switch (token.kind) {
      case 'code':
        return (
          <code
            key={i}
            className="rounded-md bg-soft px-1.5 py-0.5 font-mono text-[0.86em] [overflow-wrap:anywhere]"
          >
            {token.text}
          </code>
        );
      case 'link':
        return (
          <a
            key={i}
            href={token.href}
            className="font-medium underline decoration-2 underline-offset-[3px] hover:bg-hl"
          >
            {token.text}
          </a>
        );
      case 'text':
        return token.text;
    }
  });
}

function Section({ section }: { section: HelpSection }) {
  return (
    <div>
      {section.heading && (
        <h2 className="mt-11 mb-1 text-[26px] leading-tight font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]">
          {section.heading}
        </h2>
      )}
      {section.paragraphs?.map((p) => (
        <p key={p} className="mt-3 leading-[1.7]">
          <Inline text={p} />
        </p>
      ))}
      {section.steps && (
        <ol className="m-0 mt-3 flex list-decimal flex-col gap-2.5 pl-6 leading-[1.7] marker:font-semibold marker:text-muted">
          {section.steps.map((step) => (
            <li key={step} className="pl-1.5">
              <Inline text={step} />
            </li>
          ))}
        </ol>
      )}
      {section.list && (
        <ul className="m-0 mt-3 flex list-disc flex-col gap-2 pl-6 leading-[1.7] marker:text-muted">
          {section.list.map((item) => (
            <li key={item} className="pl-1.5">
              <Inline text={item} />
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function Breadcrumb({ article }: { article: HelpArticle }) {
  const items = getHelpBreadcrumb(article);
  return (
    <nav aria-label="Breadcrumb" className="mono text-muted">
      <ol className="m-0 flex list-none flex-wrap items-center gap-x-2 gap-y-1 p-0">
        {items.map((item, i) => (
          <li key={item.path} className="flex items-center gap-2">
            {i > 0 && <span aria-hidden="true">&rsaquo;</span>}
            {i === items.length - 1 ? (
              <span aria-current="page" className="text-ink">
                {item.name}
              </span>
            ) : (
              <a
                className="no-underline hover:text-ink hover:underline"
                href={item.path}
              >
                {item.name}
              </a>
            )}
          </li>
        ))}
      </ol>
    </nav>
  );
}

function RelatedArticles({ article }: { article: HelpArticle }) {
  const related = getRelatedArticles(article);
  return (
    <section className="mt-14" aria-labelledby="related-h">
      <h2
        id="related-h"
        className="text-[26px] leading-tight font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]"
      >
        Related articles
      </h2>
      <ul className="m-0 mt-4 grid list-none grid-cols-1 gap-4 p-0">
        {related.map((r) => (
          <li key={r.slug}>
            <a className={card} href={helpArticlePath(r.slug)}>
              <span className={`block ${cardTitle}`}>{r.title}</span>
              <span className="mt-1.5 block text-[15px] text-muted">
                {r.description}
              </span>
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}

function HelpCta() {
  return (
    <section
      className="mt-16 flex flex-col items-center gap-5 border-t-[2.5px] border-ink pt-14 pb-16 text-center"
      aria-labelledby="help-cta-h"
    >
      <h2
        id="help-cta-h"
        className={`max-w-[14ch] text-[clamp(34px,5vw,56px)] leading-[0.98] ${displayHeading}`}
      >
        Start with one thought.
      </h2>
      <p className="text-[18px] text-muted">Write it down. It comes back.</p>
      <div className="flex flex-wrap items-center justify-center gap-3.5">
        <AppStoreButton />
        <a className="btn ghost" href="/">
          About Thought Reps
        </a>
      </div>
    </section>
  );
}

export function HelpIndex() {
  return (
    <>
      <section
        className="flex max-w-[680px] flex-col gap-4 pt-10 pb-12 max-[620px]:pt-6"
        aria-labelledby="help-h"
      >
        <span className="label">Help center</span>
        <h1
          id="help-h"
          className={`text-[clamp(40px,6vw,72px)] leading-[0.96] ${displayHeading}`}
        >
          How can we help?
        </h1>
        <p className="max-w-[34em] text-[19px] text-muted">
          Short, plain guides to writing thoughts, getting them back on
          schedule, and keeping your data safe.
        </p>
      </section>
      {HELP_CATEGORIES.map((category) => (
        <section
          key={category.slug}
          className="border-t-[2.5px] border-ink py-12 max-[620px]:py-9"
          aria-labelledby={`cat-${category.slug}`}
        >
          <div className="mb-6 flex max-w-[680px] flex-col gap-2">
            <h2
              id={`cat-${category.slug}`}
              className="text-[clamp(28px,4vw,40px)] leading-tight font-black tracking-[-0.025em] [font-variation-settings:'wdth'_108]"
            >
              {category.title}
            </h2>
            <p className="text-[17px] text-muted">{category.description}</p>
          </div>
          <ul className="m-0 grid list-none grid-cols-2 gap-5 p-0 max-[620px]:grid-cols-[minmax(0,1fr)]">
            {getArticlesInCategory(category.slug).map((article) => (
              <li key={article.slug} className="flex">
                <a
                  className={`${card} w-full`}
                  href={helpArticlePath(article.slug)}
                >
                  <h3 className={cardTitle}>{article.title}</h3>
                  <p className="mt-1.5 text-[15px] text-muted">
                    {article.description}
                  </p>
                </a>
              </li>
            ))}
          </ul>
        </section>
      ))}
      <HelpCta />
    </>
  );
}

export function HelpArticleView({ article }: { article: HelpArticle }) {
  return (
    <>
      <article className="mx-auto max-w-[65ch] pt-6 pb-4">
        <Breadcrumb article={article} />
        <header className="mt-8 flex flex-col gap-4">
          <h1
            className={`text-[clamp(34px,5vw,54px)] leading-[1] ${displayHeading}`}
          >
            {article.title}
          </h1>
          <p className="text-[19px] text-muted">{article.description}</p>
        </header>
        <div className="mt-2">
          {article.sections.map((section, i) => (
            <Section key={section.heading ?? i} section={section} />
          ))}
        </div>
        <RelatedArticles article={article} />
        <a className="btn ghost mt-12" href={HELP_INDEX_PATH}>
          Back to Help center
        </a>
      </article>
      <HelpCta />
    </>
  );
}
