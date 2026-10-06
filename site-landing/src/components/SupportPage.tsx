import { getHelpArticle, helpArticlePath } from '../content/help';
import {
  SUPPORT_BEFORE_SECTION,
  SUPPORT_CLOSING,
  SUPPORT_CONTACT_SECTION,
  SUPPORT_HELP_SLUGS,
  SUPPORT_INTRO,
  SUPPORT_MORE_HELP,
  SUPPORT_QUESTIONS_HEADING,
  type SupportSection,
} from '../content/support';
import { Inline } from './Help';
import { Nav } from './Hero';
import { Footer } from './Sections';
import { Sprites } from './shared';

const h2Class =
  "mt-11 mb-1 text-[26px] leading-tight font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]";
const listClass =
  'm-0 mt-3 flex list-disc flex-col gap-2 pl-6 leading-[1.7] marker:text-muted';
const linkClass =
  'font-medium underline decoration-2 underline-offset-[3px] hover:bg-hl';

function Section({ section }: { section: SupportSection }) {
  return (
    <section>
      <h2 className={h2Class}>{section.heading}</h2>
      {section.paragraphs?.map((p) => (
        <p key={p} className="mt-3 leading-[1.7]">
          <Inline text={p} />
        </p>
      ))}
      {section.list && (
        <ul className={listClass}>
          {section.list.map((item) => (
            <li key={item} className="pl-1.5">
              <Inline text={item} />
            </li>
          ))}
        </ul>
      )}
      {section.after?.map((p) => (
        <p key={p} className="mt-3 leading-[1.7]">
          <Inline text={p} />
        </p>
      ))}
    </section>
  );
}

export function SupportPage() {
  const articles = SUPPORT_HELP_SLUGS.flatMap((slug) => {
    const article = getHelpArticle(slug);
    return article ? [article] : [];
  });
  return (
    <>
      <Sprites />
      <div className="mx-auto max-w-[1140px]">
        <Nav base="/" />
        <main>
          <article className="mx-auto max-w-[65ch] pt-6 pb-16">
            <header className="flex flex-col gap-4">
              <h1 className="text-[clamp(34px,5vw,54px)] leading-[1] font-black tracking-[-0.03em] [font-variation-settings:'wdth'_110]">
                Support
              </h1>
              <p className="text-[19px] text-muted">{SUPPORT_INTRO}</p>
            </header>
            <Section section={SUPPORT_CONTACT_SECTION} />
            <Section section={SUPPORT_BEFORE_SECTION} />
            <section>
              <h2 className={h2Class}>{SUPPORT_QUESTIONS_HEADING}</h2>
              <ul className={listClass}>
                {articles.map((article) => (
                  <li key={article.slug} className="pl-1.5">
                    <a
                      className={linkClass}
                      href={helpArticlePath(article.slug)}
                    >
                      {article.title}
                    </a>
                  </li>
                ))}
                {SUPPORT_MORE_HELP.map((item) => (
                  <li key={item.href} className="pl-1.5">
                    <a className={linkClass} href={item.href}>
                      {item.text}
                    </a>
                  </li>
                ))}
              </ul>
            </section>
            <p className="mt-11 text-[15px] text-muted">{SUPPORT_CLOSING}</p>
          </article>
        </main>
        <Footer base="/" />
      </div>
    </>
  );
}
