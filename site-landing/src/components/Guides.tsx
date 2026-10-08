import { getHelpArticle, helpArticlePath } from '../content/help';
import {
  formatGuideDate,
  getGuideBreadcrumb,
  GUIDES,
  guidePath,
  type Guide,
} from '../content/guides';
import {
  Breadcrumb,
  card,
  cardTitle,
  displayHeading,
  HelpCta,
  Section,
} from './Help';

export function GuideCards({ guides = GUIDES }: { guides?: Guide[] }) {
  return (
    <ul className="m-0 grid list-none grid-cols-2 gap-5 p-0 max-[620px]:grid-cols-[minmax(0,1fr)]">
      {guides.map((guide) => (
        <li key={guide.slug} className="flex">
          <a className={`${card} w-full`} href={guidePath(guide.slug)}>
            <h3 className={cardTitle}>{guide.title}</h3>
            <p className="mt-1.5 text-[15px] text-muted">{guide.description}</p>
          </a>
        </li>
      ))}
    </ul>
  );
}

export function GuideIndex() {
  return (
    <>
      <section
        className="flex max-w-[680px] flex-col gap-4 pt-10 pb-12 max-[620px]:pt-6"
        aria-labelledby="guides-h"
      >
        <span className="label">Guides</span>
        <h1
          id="guides-h"
          className={`text-[clamp(40px,6vw,72px)] leading-[0.96] ${displayHeading}`}
        >
          Keep what you learn.
        </h1>
        <p className="max-w-[34em] text-[19px] text-muted">
          Longer reads on the ideas behind Thought Reps: writing things down,
          and making sure you see them again.
        </p>
      </section>
      <section className="border-t-[2.5px] border-ink py-12 max-[620px]:py-9">
        <h2 className="sr-only">All guides</h2>
        <GuideCards />
      </section>
      <HelpCta />
    </>
  );
}

export function GuideArticleView({ guide }: { guide: Guide }) {
  const related = guide.relatedHelp.flatMap(
    (slug) => getHelpArticle(slug) ?? [],
  );
  const date = guide.updated ?? guide.published;
  return (
    <>
      <article className="mx-auto max-w-[65ch] pt-6 pb-4">
        <Breadcrumb items={getGuideBreadcrumb(guide)} />
        <header className="mt-8 flex flex-col gap-4">
          <h1
            className={`text-[clamp(34px,5vw,54px)] leading-[1] ${displayHeading}`}
          >
            {guide.title}
          </h1>
          <p className="text-[19px] text-muted">{guide.description}</p>
          <p className="mono text-muted">
            {guide.updated ? 'Updated ' : ''}
            <time dateTime={date}>{formatGuideDate(date)}</time>
          </p>
        </header>
        <div className="mt-2">
          {guide.sections.map((section, i) => (
            <Section key={section.heading ?? i} section={section} />
          ))}
        </div>
        <section className="mt-14" aria-labelledby="related-h">
          <h2
            id="related-h"
            className="text-[26px] leading-tight font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]"
          >
            Learn the app
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
      </article>
      <HelpCta />
    </>
  );
}
