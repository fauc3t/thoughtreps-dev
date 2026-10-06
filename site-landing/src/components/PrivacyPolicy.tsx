import {
  formatLastUpdated,
  LAST_UPDATED,
  PRIVACY_SECTIONS,
} from '../content/privacy';
import { Inline } from './Help';
import { Nav } from './Hero';
import { Footer } from './Sections';
import { Sprites } from './shared';

export function PrivacyPolicy() {
  return (
    <>
      <Sprites />
      <div className="mx-auto max-w-[1140px]">
        <Nav base="/" />
        <main>
          <article className="mx-auto max-w-[65ch] pt-6 pb-16">
            <header className="flex flex-col gap-4">
              <h1 className="text-[clamp(34px,5vw,54px)] leading-[1] font-black tracking-[-0.03em] [font-variation-settings:'wdth'_110]">
                Privacy policy
              </h1>
              <p className="text-[19px] text-muted">
                Last updated{' '}
                <time dateTime={LAST_UPDATED}>{formatLastUpdated()}</time>
              </p>
            </header>
            {PRIVACY_SECTIONS.map((section) => (
              <section key={section.heading}>
                <h2 className="mt-11 mb-1 text-[26px] leading-tight font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]">
                  {section.heading}
                </h2>
                {section.paragraphs?.map((p) => (
                  <p key={p} className="mt-3 leading-[1.7]">
                    <Inline text={p} />
                  </p>
                ))}
                {section.list && (
                  <ul className="m-0 mt-3 flex list-disc flex-col gap-2 pl-6 leading-[1.7] marker:text-muted">
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
            ))}
          </article>
        </main>
        <Footer base="/" />
      </div>
    </>
  );
}
