// Source of truth for the /privacy page. The page, its meta tags, the sitemap
// entry and the prerender route all read from here. Every claim must match what
// the app, the site and infra/ actually do. Update LAST_UPDATED on any change.

export const PRIVACY_PATH = '/privacy';

export const LAST_UPDATED = '2026-10-06';

export const PRIVACY_TITLE = 'Privacy policy | Thought Reps';

export const PRIVACY_DESCRIPTION =
  'How Thought Reps handles your data. Your thoughts stay on your phone, and we can never read them. No account, no ads, no analytics, no tracking.';

export interface PrivacySection {
  heading: string;
  paragraphs?: string[];
  list?: string[];
  after?: string[];
}

export function formatLastUpdated(date: string = LAST_UPDATED): string {
  const [year, month, day] = date.split('-').map(Number);
  return new Intl.DateTimeFormat('en-US', {
    dateStyle: 'long',
    timeZone: 'UTC',
  }).format(new Date(Date.UTC(year, month - 1, day)));
}

export const PRIVACY_SECTIONS: PrivacySection[] = [
  {
    heading: 'The short version',
    paragraphs: [
      'Your thoughts stay on your phone, and we can never read them.',
    ],
    list: [
      'No account.',
      'No ads.',
      'No analytics.',
      'No tracking.',
      'We never sell your data, and we never share it for advertising.',
    ],
  },
  {
    heading: 'Who we are',
    paragraphs: [
      'Thought Reps LLC is a company in New York, US. This policy covers the Thought Reps iPhone app, thoughtreps.com, and transfer.thoughtreps.com.',
      'Questions? Email [hello@thoughtreps.com](mailto:hello@thoughtreps.com).',
    ],
  },
  {
    heading: 'On your phone',
    paragraphs: [
      'Your thoughts, images, tags and settings are stored in the app, on your iPhone. We never receive your thoughts in a form we can read.',
      'If you make an export link, an encrypted copy is uploaded. It is deleted after one download or 24 hours. See Export links below.',
      'Notifications are scheduled on your phone. The share extension does not use the internet.',
      'A backup (a `.thoughtreps` file) goes wherever you save it, like Files, AirDrop or iCloud Drive. That is between you and that service.',
    ],
  },
  {
    heading: 'When the app uses the internet',
    paragraphs: [
      'The app only uses the internet for two things, and you start both yourself:',
    ],
    list: [
      'Sending feedback.',
      'Creating, checking, revoking or importing an export link.',
    ],
    after: [
      "Requests are signed with Apple's App Attest. It creates a key that is unique to this install of the app. We store that key's ID and public key. This is your device ID. That lets us accept requests only from real copies of the app, and limit how often one install can ask (feedback is 3 per install per day).",
    ],
  },
  {
    heading: 'Feedback',
    paragraphs: [
      'When you send feedback, we receive your message (customer support), the email address you enter, and the type (feature request or problem report). We also get your app version, iOS version and device model, a short device ID (the install ID), and when it was sent. Your thoughts are never included.',
      'It is delivered as an email at hello@thoughtreps.com through Amazon SES. The email address is remembered on your phone so it is filled in next time.',
      'We use it only to read it and reply. We keep it in our support inbox until we delete it, or until you ask us to delete it.',
      'To limit feedback, we keep a daily count per install ID. We delete it after 2 days.',
    ],
  },
  {
    heading: 'Export links',
    paragraphs: [
      'Your backup file is encrypted on your iPhone (AES-256-GCM) before it is uploaded. The key is only in the part of the link after the `#`. Browsers never send that part to a server, so we cannot read the file.',
      'The file is deleted after one download, or after 24 hours, whichever comes first. If something goes wrong, a backup rule deletes it within 2 days at most. You can revoke the link in Settings sooner.',
      'Our server keeps a record of the link. It has the link ID, the file size, a checksum of the encrypted file, when the link was created, used and expires, and the device ID. We delete this record about 7 days after the link expires.',
      'The record of your install key stays so the app keeps working. You can ask us to delete it.',
      'When you open a link in a browser, or import it in the app, the file is downloaded and decrypted on that device.',
    ],
  },
  {
    heading: 'The website and download page',
    paragraphs: [
      'thoughtreps.com and transfer.thoughtreps.com use no cookies, no analytics, and no ad or tracking scripts. Fonts are served from our own site, not from a third party.',
      'If you pick light or dark mode, your browser remembers the choice on your device. It is never sent to us.',
      'Our hosting provider may process standard request data, like your IP address and browser (user agent), to serve pages. We do not turn on access logs for the website, the download page or our API. Our API keeps only error logs. They do not include your thoughts or your feedback.',
    ],
  },
  {
    heading: 'Service providers',
    paragraphs: [
      'We use Amazon Web Services for hosting, the API, storage of encrypted export files, and email delivery (Amazon SES). Error logs go to Amazon CloudWatch. Data is stored and processed in the United States. We use Apple for the App Store and App Attest. Notifications are delivered locally by your phone.',
      "We don't sell or share personal information, as those terms are defined in US state privacy laws like California's.",
    ],
  },
  {
    heading: 'Your choices and rights',
    paragraphs: [
      'You can use the app without ever sending anything.',
      'Email [hello@thoughtreps.com](mailto:hello@thoughtreps.com) to ask what we hold, or to delete your feedback or link records. We respond within 30 days.',
      'People in some places, like California and the EU and UK, have extra rights. We honor these requests for everyone.',
    ],
  },
  {
    heading: 'Children',
    paragraphs: [
      'Thought Reps is not directed at children under 13. We do not knowingly collect their data. If you think we have, contact us and we will delete it.',
    ],
  },
  {
    heading: 'Security',
    paragraphs: [
      'Data is encrypted in transit (HTTPS). Export files are encrypted on your device. Only the small team that runs Thought Reps can access our support inbox and servers.',
    ],
  },
  {
    heading: 'Changes',
    paragraphs: [
      'If this policy changes, we will update this page and the date at the top. We will note meaningful changes on the page.',
    ],
  },
];
