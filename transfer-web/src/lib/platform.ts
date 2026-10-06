// iPadOS reports a Mac user agent, so iPad is intentionally not detected.
export function isIPhone(): boolean {
  return /iPhone|iPod/.test(navigator.userAgent);
}
