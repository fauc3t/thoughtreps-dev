if (new URLSearchParams(location.search).get('theme') === 'dark') document.documentElement.dataset.theme = 'dark';
const stage = document.getElementById('stage');
const fit = () => (stage.style.transform = `translate(-50%,-50%) scale(${innerWidth / 3840})`);
fit();
addEventListener('resize', fit);

// Same easing as CSS cubic-bezier(x1,y1,x2,y2).
const bezier = (x1, y1, x2, y2) => (x) => {
  const c = (a, b, t) => 3 * a * (1 - t) ** 2 * t + 3 * b * (1 - t) * t * t + t ** 3;
  let lo = 0, hi = 1;
  for (let i = 0; i < 30; i++) {
    const m = (lo + hi) / 2;
    if (c(x1, x2, m) < x) lo = m; else hi = m;
  }
  return c(y1, y2, (lo + hi) / 2);
};
const clamp01 = (x) => Math.min(1, Math.max(0, x));
const lerp = (a, b, p) => a + (b - a) * p;
const LOOP_SYMBOL = `<svg width="0" height="0" style="position:absolute" aria-hidden="true"><symbol id="loop" viewBox="0 0 24 24"><path d="M17.3 6.1A8 8 0 1 1 6.3 6.6" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"/><path d="M3.2 3.6L8.6 3.3L8.2 9.1Z" fill="currentColor" stroke="currentColor" stroke-width="1" stroke-linejoin="round"/></symbol></svg>`;
document.body.insertAdjacentHTML('afterbegin', LOOP_SYMBOL);

// Real copy from NOTES in site-landing/src/components/Hero.tsx.
const NOTES = [
  { title: 'One wild and precious life', body: '“Tell me, what is it you plan to do with your one wild and precious life?” — Mary Oliver', tag: '#quotes', due: 'due today', quiet: false },
  { title: 'Read later: the case for slow email', body: "Saved Tuesday, 12 min read. You said you'd get to it.", tag: '#toread', due: 'due 2d ago', quiet: false },
  { title: 'Weekly review questions', body: 'What moved forward? What stalled? What do I want to stop doing?', tag: '#habits', due: 'pinned', quiet: true },
];
