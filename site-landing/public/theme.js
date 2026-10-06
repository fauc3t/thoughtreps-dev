// Light/dark toggle, loaded as a classic blocking script in <head> so a saved
// choice applies before first paint (no flash). No saved choice follows the OS;
// picking the OS's own theme clears the saved choice again. Clicks are handled
// by delegation so it also works on pages that aren't hydrated.
(function () {
  var root = document.documentElement;
  var KEY = 'theme';
  var dark = window.matchMedia('(prefers-color-scheme: dark)');
  try {
    var saved = localStorage.getItem(KEY);
    if (saved === 'light' || saved === 'dark')
      root.setAttribute('data-theme', saved);
  } catch {
    // Storage blocked (private mode, disabled site data): follow the OS.
  }
  document.addEventListener('click', function (event) {
    var target = event.target;
    var button =
      target && target.closest && target.closest('[data-theme-toggle]');
    if (!button) return;
    var system = dark.matches ? 'dark' : 'light';
    var current = root.getAttribute('data-theme') || system;
    var next = current === 'dark' ? 'light' : 'dark';
    try {
      if (next === system) localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, next);
    } catch {
      // Storage blocked: the choice lasts for this page only.
    }
    if (next === system) root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', next);
  });
})();
