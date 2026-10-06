// Source of truth for the /support page (the App Store "Support URL"). Labels
// must match SettingsView.swift. Help links are slugs from help.ts.

export const SUPPORT_PATH = '/support';

export const SUPPORT_TITLE = 'Support | Thought Reps';

export const SUPPORT_DESCRIPTION =
  'Need a hand with Thought Reps? Send feedback from the app or email hello@thoughtreps.com. We usually reply within a few business days.';

export const SUPPORT_INTRO = 'Need a hand? Here is how to reach us.';

export const SUPPORT_HELP_SLUGS = [
  'write-your-first-thought',
  'daily-reminders',
  'backup-and-restore',
  'move-to-a-new-phone',
  'privacy',
  'faq',
];

export const SUPPORT_CLOSING =
  'Thought Reps is made by Thought Reps LLC, New York, US.';

export interface SupportSection {
  heading: string;
  paragraphs?: string[];
  list?: string[];
  after?: string[];
}

export const SUPPORT_CONTACT_SECTION: SupportSection = {
  heading: 'Contact us',
  paragraphs: [
    'In the app, open Settings, then tap "Request a Feature" or "Report a Problem" under "Send Feedback". It includes your app version, iOS version and device model, so it is the fastest way to reach us.',
    'Or email [hello@thoughtreps.com](mailto:hello@thoughtreps.com). We usually reply within a few business days.',
    'You can send three messages from the app per day.',
  ],
};

export const SUPPORT_BEFORE_SECTION: SupportSection = {
  heading: 'Before you write',
  paragraphs: ['If you email us, it helps to include:'],
  list: [
    'Your iPhone model.',
    'Your iOS version. You can find it in the Settings app on your iPhone, under General, then About.',
    'Your app version. It is at the bottom of Thought Reps Settings, next to "Version".',
    'What happened, and what you expected.',
  ],
  after: ['Never paste your thoughts unless you want to share them.'],
};

export const SUPPORT_QUESTIONS_HEADING = 'Common questions';

export const SUPPORT_MORE_HELP = [
  { text: 'Browse the whole Help center', href: '/help' },
  { text: 'Read the privacy policy', href: '/privacy' },
];
