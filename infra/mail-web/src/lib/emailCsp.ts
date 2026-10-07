// The srcdoc iframe inherits the page's CSP, which already blocks remote
// images; this meta is defence in depth. It goes after any leading doctype,
// since content before one forces quirks mode.
const EMAIL_CSP_META =
  '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'">';

export function withEmailCsp(html: string): string {
  return html.replace(
    /^\s*(<!doctype[^>]*>)?/i,
    (lead) => lead + EMAIL_CSP_META,
  );
}
