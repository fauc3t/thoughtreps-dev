// mountTimeline(opts) builds the drifting timeline in #stage and returns render(d), where d is the drift in weeks.
// Content repeats every 3 weeks, so d=3 equals d=0. Needs shared.js and timeline.css.
function mountTimeline({ K, S, W, H, CX, LINE, REST, LIFT, half = 3.5 }) {
  const smooth = (x) => x * x * (3 - 2 * x);
  const mod = (n, m) => ((n % m) + m) % m;
  const N = [];
  for (let n = -4; n <= 7; n++) N.push(n);
  stage.insertAdjacentHTML('beforeend', `<div id="line" style="top:${LINE}px"></div>`);

  const items = N.map((n) => {
    const note = NOTES[mod(n, 3)];
    const stem = Object.assign(document.createElement('div'), { className: 'stem' });
    const dot = Object.assign(document.createElement('div'), { className: 'dot' });
    const gap = Object.assign(document.createElement('span'), { className: 'chip gap', textContent: '7 days' });
    const card = document.createElement('article');
    card.className = 'note stk';
    Object.assign(card.style, { width: W + 'px', height: H + 'px', left: -W / 2 + 'px', top: -H + 'px' });
    card.innerHTML = `<span class="title">${note.title}</span><div class="foot"><span class="chip">${note.tag}</span><div class="duebox"><span class="due quiet past">seen</span><span class="due now">back today</span><span class="due quiet next">due in 7 days</span></div></div><div class="badge stk rise"><svg class="loop"><use href="#loop" /></svg></div>`;
    stage.append(stem, dot, gap, card);
    return { n, stem, dot, gap, card, past: card.querySelector('.past'), now: card.querySelector('.now'), next: card.querySelector('.next'), rise: card.querySelector('.rise') };
  });

  const render = (d) => {
    for (const it of items) {
      const dist = it.n - d, x = CX + dist * S;
      const b = smooth(clamp01(1 - Math.abs(dist) / 0.9));
      const bottom = LINE - REST - LIFT * b;
      const rot = lerp((mod(it.n, 3) - 1) * 1.6, 0, b);
      const c = it.card.style;
      c.left = x - W / 2 + 'px';
      c.top = bottom - H + 'px';
      c.transform = `rotate(${rot}deg) scale(${1 + 0.1 * b})`;
      c.transformOrigin = '50% 100%';
      c.background = `color-mix(in srgb, var(--paper) ${b * 100}%, var(--soft))`;
      const o = lerp(4, 8, b) * K;
      c.boxShadow = `${o}px ${o}px 0 var(--ink)`;
      it.stem.style.cssText = `left:${x - half}px;top:${bottom}px;height:${LINE - bottom}px`;
      it.dot.style.cssText = `left:${x}px;top:${LINE + half}px;transform:scale(${1 + 0.5 * b});background:${b > 0.5 ? 'var(--ink)' : 'var(--paper)'}`;
      it.gap.style.cssText = `left:${x + S / 2}px;top:${LINE + half}px`;
      const calm = clamp01(1 - b / 0.35), shown = clamp01((b - 0.65) / 0.35);
      it.now.style.opacity = shown;
      it.past.style.opacity = dist < 0 ? calm : 0;
      it.next.style.opacity = dist < 0 ? 0 : calm;
      it.rise.style.opacity = shown;
      it.rise.style.transform = `scale(${0.4 + 0.6 * shown})`;
    }
  };
  render(0);
  return render;
}
