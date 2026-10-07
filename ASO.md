# Thought Reps — App Store Optimization

Oct 7, 2026

The store page has to sell a $6.99 app with no trial, and most people decide from the icon, subtitle and first three screenshots in search results. This spec covers what those surfaces say and how we test and measure them. It builds on the App Store listing section of the Launch Plan (`designs/Thought Reps — Launch Plan.md`) rather than repeating it.

## Positioning

The promise is the landing site's headline: **Write it down. It comes back.** Every store surface repeats that one loop before listing any feature.

- **Who it's for:** people who save quotes, ideas and links and never look at them again. The secondary audience is spaced-repetition users who want something lighter than Anki.
- **Why pay $6.99:** it's bought once, with no subscription and no account, and your thoughts stay on your phone. Paid utilities convert on trust, so this goes in a screenshot, not just the description.
- **What we don't claim:** growing intervals, sync, or Markdown export. All three are post-launch, and a store claim that doesn't match the app leads to 1-star reviews and rejection risk.
- **Tone:** plain and a little warm, like the landing site. No emojis.

## Metadata

Search ranking uses the name, the subtitle and the keywords field. The description isn't indexed, so it's written for conversion, not keywords.

| Field | Limit (chars) | Draft | Notes |
| --- | --- | --- | --- |
| Name | 30 | Thought Reps | Reserve it by creating the App Store Connect record. |
| Subtitle | 30 | Spaced repetition thought log (29) | Highest-weight free text after the name. The wording is an open decision (below). |
| Keywords | 100 | `notes,journal,ideas,remember,resurface,reflect,markdown,quotes,commonplace,memory,recall,brain` (94) | Commas, no spaces. Don't repeat words from the name or subtitle, and no competitor names (guideline 2.3.7). |
| Promotional text | 170 | Write it down in five seconds. A week later it's back on your timeline, so the good ideas get a second look. $6.99 once. No account, no subscription. (149) | Can change without review, so use it for launch messages and updates. |
| Description | 4,000 | Not yet written | The first 3 lines show before "more", so they carry the loop and the price. Then features, privacy, and how resurfacing works in 1.0 (a fixed interval). |
| Category | n/a | Productivity, with Education as the secondary | Paid Productivity is a smaller chart to place in than Free. |
| What's New | 4,000 | Not yet written | For 1.0, one line. After that, write real notes, because people do read them. |

Revisit the keywords after 2 to 4 weeks of impressions data. Swap out any term that brings impressions but no downloads.

## Screenshots and creative

Search results show the first three portrait screenshots, so frames 1 to 3 have to sell the app without any other help. The Launch Plan's order is reshuffled here so that the loop, capture and trust come first.

| # | Caption (draft) | Shows |
| --- | --- | --- |
| 1 | Write it down. It comes back. | The timeline with due thoughts and the "due today" chips |
| 2 | Capture a thought in five seconds | The editor with Markdown and an image |
| 3 | $6.99 once. No account. Stays on your phone. | A calm timeline or settings shot, with the price in the caption |
| 4 | Every tag gets its own timeline | The tag timeline, with custom colors |
| 5 | Find anything you've ever saved | Search results |
| 6 | Hide spoilers and answers until you're ready | A blurred block, before and after |
| 7 | Save from anywhere | The share sheet from Safari |
| 8 | A gentle daily nudge | The reminder notification and snooze |

- **Spec:** 6.9" iPhone at 1320×2868 is required, and Apple scales it for smaller devices. Up to 10 shots are allowed; plan 6 to 8.
- **Content:** realistic sample thoughts (quotes, reading notes, ideas), not debug seed data. Use the landing site's look: paper ground, ink borders and indigo accent.
- **Captions:** 5 to 7 words, readable at search-result size. They're also a ranking signal, according to ASO tools' reports, so use the keyword terms where it reads naturally.
- **Light and dark:** shoot light first. A dark set is a good first A/B test (see Discovery).
- **App preview video:** skip for 1.0. If we make one later, show 15 to 20 seconds of the loop: write, wait, it's back. Previews autoplay muted, so the captions have to carry it.
- **Icon:** done (the 3D bubble). Check it next to competitors in a real search results screenshot.

## Ratings and reviews

Ratings decide conversion on a paid app more than any other surface. Show the one prompt at the moment the loop works for someone, not at launch.

- **Trigger:** `requestReview` after a person has reviewed their 3rd resurfaced thought (opened it, or marked it done or snoozed it), and at least 7 days after install. Never after an error, an import or the first launch. iOS caps it at 3 prompts in 365 days and may not show it at all, so one well-timed call is enough.
- **No in-app nag or pre-prompt** of the "Enjoying Thought Reps?" kind. Send unhappy users to Send Feedback through Settings instead, where they already are.
- **Launch week:** ask TestFlight testers to rate and review the public build when it goes live. Ask genuinely, with no incentives (guideline 5.6.3).
- **Replies:** answer every review under 3 stars within 48 hours in App Store Connect. The reply is public, and the reviewer gets a notification and can update their review.
- **Don't reset ratings** on early updates unless the 1.0 rating is sunk by a bug that has since been fixed.

## Discovery beyond search

Pre-order and a featuring nomination are the two levers with the most leverage for launch. The rest are cheap follow-ups once there's traffic to learn from.

| Lever | What it does for us | When | Effort |
| --- | --- | --- | --- |
| Pre-order | It gives us a real App Store URL before launch, so the landing site's "coming soon" badge and Smart App Banner can link now. Buyers are charged on release day, which concentrates launch-day downloads. | After the 1.0 build passes review, about 2 weeks before release | Low |
| Featuring nomination | It pitches the launch to Apple's editors from App Store Connect. The story is an indie, local-first app with no account or subscription, plus the accessibility work. | Submit several weeks before release | Low |
| Accessibility Nutrition Labels | They show which features are supported (VoiceOver, Larger Text, Dark Interface, Reduced Motion) on the product page. | With the Launch Plan's accessibility pass | Low |
| Product Page Optimization | It A/B tests the icon or screenshots against up to 3 treatments. The first test: light vs dark screenshots, then the order of frame 3. | 2 to 4 weeks after launch, once there are impressions | Medium |
| Custom product pages | These are alternate pages with their own screenshots and keywords. Candidates: "for Anki users", "for readers and quote collectors", and "for journaling". | After launch, once keyword data shows which audience converts | Medium |
| In-App Events | Event cards in search and the Today tab. A natural first one is the Study mode launch. | The first big post-launch update | Low |
| Apple Ads | Paid search placement. Start with a small exact-match budget on our own name (to stop competitors bidding on it) and 5 to 10 generic terms. | Launch week, with a cap of $10 to $20 a day | Low |
| Metadata localizations | Add English (UK, Australia, Canada) listings so those storefronts get their own keyword fields. | After the US keywords settle | Low |

## Measurement

App Store Connect's App Analytics covers everything we need. The app has no analytics SDK, and this plan doesn't add one.

| Metric | Where | What it tells us |
| --- | --- | --- |
| Impressions by source (search, browse, web referrer) | App Analytics, Acquisition | Whether keywords and featuring are bringing people to the listing |
| Product page conversion rate | App Analytics, Metrics | Whether the screenshots and price are selling. This is the number the A/B tests move. |
| Search terms driving downloads | App Analytics, Acquisition and Apple Ads reports | Which keywords to keep and which to swap |
| Ratings count and average | Ratings and Reviews | Whether the prompt timing works |
| Refund rate | Sales and Trends | Whether the listing promises what the app does |
| Web referrer: thoughtreps.com | App Analytics | How much the landing site contributes |

Review these weekly for the first month, then monthly. Record each metadata or screenshot change with its date, so a shift can be traced to the change that caused it.

## Checklist

**Before the first TestFlight build**

- [ ] Settle the subtitle and the price wording (see Open decisions)
- [ ] Create the App Store Connect record to reserve the name
- [ ] Add the rating-prompt trigger (3rd resurfaced thought reviewed, 7+ days after install)
- [ ] Build a realistic sample-content set for screenshots, separate from the debug seed

**Before submitting 1.0**

- [ ] Finalize the keywords, promotional text and description
- [ ] Make screenshots 1 to 6 at 1320×2868 with captions
- [ ] Declare the Accessibility Nutrition Labels after the accessibility pass
- [ ] Fix the landing hero's "Free" label and the Markdown export claim
- [ ] Submit the featuring nomination

**Launch window**

- [ ] Turn on pre-order, then link the App Store badge and add the Smart App Banner on the landing site and transfer-web
- [ ] Ask TestFlight testers to rate the public build
- [ ] Start Apple Ads on our name and 5 to 10 generic terms

**After launch (weeks 2 to 6)**

- [ ] Reply to every review under 3 stars within 48 hours
- [ ] Swap keywords that bring impressions but no downloads
- [ ] Run the first Product Page Optimization test (light vs dark screenshots)
- [ ] Build one custom product page for the best-converting audience

## Open decisions

1. **Subtitle.** Recommended: **Notes that come back to you** (27). It describes 1.0 accurately, since thoughts come back on a fixed interval. "Spaced repetition thought log" ranks for a term with real search volume, but Anki users will expect growing intervals. A third option keeps both: use the recommended subtitle and put `spaced,repetition` in the keywords. To fit 100 characters, drop `notes` (now in the subtitle) and `brain`, which uses exactly 100 characters.
2. **Price on the website.** Decided: $6.99, bought once (Oct 7, 2026). The landing hero now shows it.
3. **Pre-order.** Recommended: yes, for about 2 weeks. The cost is that the 1.0 build has to pass review before the pre-order starts.
4. **Apple Ads budget.** Recommended: $10 to $20 a day for the first 30 days, then keep only the terms with a cost per download under about half the price.
