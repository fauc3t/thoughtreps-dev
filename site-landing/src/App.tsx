import { Hero, Nav } from './components/Hero';
import {
  Features,
  FinalCta,
  Footer,
  HowItWorks,
  Privacy,
} from './components/Sections';
import { Sprites } from './components/shared';

export function LandingPage() {
  return (
    <>
      <Sprites />
      <div className="mx-auto max-w-[1140px]">
        <Nav />
        <main id="top">
          <Hero />
          <HowItWorks />
          <Features />
          <Privacy />
          <FinalCta />
        </main>
        <Footer />
      </div>
    </>
  );
}

export function NotFoundPage() {
  return (
    <>
      <Sprites />
      <div className="mx-auto max-w-[1140px]">
        <main className="flex min-h-[70vh] flex-col items-start justify-center gap-6 py-16">
          <span className="label">404</span>
          <h1 className="text-[clamp(46px,7.4vw,92px)] leading-[0.92] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112]">
            That thought didn&apos;t come back.
          </h1>
          <p className="max-w-[33em] text-[19px] text-muted">
            There&apos;s no page at this address.
          </p>
          <a className="btn ghost" href="/">
            Back to Thought Reps
          </a>
        </main>
      </div>
    </>
  );
}
