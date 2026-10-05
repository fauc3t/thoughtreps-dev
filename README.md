# Thought Reps

A local-first iPhone app for capturing thoughts and having them come back on a schedule. You write a thought in Markdown, and it reappears on your timeline after its interval (7 days by default). Opening a thought queues it up again. Share text, a link, or a Markdown file from any app to add a thought without opening Thought Reps. You can pin thoughts to keep them visible, archive them to retire them, and file them with `#hashtags`.

Design: [`designs/`](designs/) holds the spec and the screen mockups.

## Requirements

- macOS with **Xcode 16** or later (for iOS 18+ SDK and Swift Testing)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), which generates the Xcode project from `project.yml`
- A paid Apple Developer account signed in to Xcode (installs last a year; TestFlight and iCloud are available)

## First-time setup

See [DEVELOPMENT.md](DEVELOPMENT.md) for setup and everyday commands. In short:

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM
xcodegen
open ThoughtReps.xcodeproj
```

To find your Team ID, go to **Xcode > Settings > Accounts**, select your Apple ID, and look under your paid team. Another way: open the generated project, pick your team under **Signing & Capabilities**, and copy the `DEVELOPMENT_TEAM` value into `Config/Local.xcconfig` so it survives the next `xcodegen`.

If Xcode says the bundle ID is unavailable, set `TR_BUNDLE_ID` in `Config/Local.xcconfig` to something unique, such as `com.yourname.thoughtreps`. The App Group ID (`group.<bundle id>`) follows it automatically.

## Everyday workflow

- `ThoughtReps.xcodeproj` is generated and gitignored. Run `xcodegen` again after pulling, or after adding or removing files.
- The first build resolves Swift packages (MarkdownUI). If that fails, run `xcodebuild -resolvePackageDependencies -scheme ThoughtReps`. `ThoughtReps.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is tracked; commit it when dependency versions change.
- Run tests with **⌘U** in Xcode, or from the command line:
  `xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'`
  (pick a name from `xcrun simctl list devices available`)
- Images are stored in the SwiftData store (`default.store` in Application Support); larger image bytes go to `.default_SUPPORT/_EXTERNAL_DATA` beside it. The camera needs a real device (the simulator has no camera).
- Debug builds seed sample thoughts on first launch. **Settings > Developer** can add more or wipe everything.

## Running on your iPhone

1. Plug in the phone (or pair it over Wi-Fi), and enable **Developer Mode** under Settings > Privacy & Security.
2. Choose the phone as the run destination and press **⌘R**.
3. The first time, trust the developer certificate under Settings > General > VPN & Device Management.

With a paid developer account the install lasts a year. (A free Apple ID also works, but installs expire after 7 days and iCloud isn't available.)

## Project layout

```
ThoughtReps/
  App/          App entry, tab bar, navigation destinations
  Models/       SwiftData models: Thought, Tag, Block, ImageAsset
  Scheduler/    Resurfacing rules as pure, unit-tested functions
  Stores/       ThoughtStore (all writes), ThoughtCounts (count queries), IntegrityChecker, SaveErrorCenter, AppSettings
  Services/     TagParser, NotificationScheduler, AppNavigation, InboxImporter, ImageProcessor, ImageToken
  Features/     Timeline, Thought, Editor, Blocks, Tags, Archive, Settings
  Resources/    Assets, sample data
Shared/            Inbox file format shared by the app and the share extension
ThoughtRepsShare/  Share extension ("New Thought" sheet)
ThoughtRepsTests/  Scheduler, TagParser, MarkdownFormatter, store, integrity and persistence tests (Swift Testing)
Config/            Shared xcconfig; your Local.xcconfig (gitignored)
project.yml        XcodeGen spec
landing/           Static HTML landing-page design prototypes (not part of the app)
site-landing/      The real landing site for thoughtreps.com (Vite + React, prerendered)
infra/             AWS CDK app (DNS, landing hosting, email) and the mail inbox UI (infra/mail-web)
scripts/           Manual deploy scripts for the landing site and mail UI
```

The web side is a separate pnpm workspace; see [DEVELOPMENT.md](DEVELOPMENT.md#web-and-infrastructure) and [INTEGRATIONS.md](INTEGRATIONS.md) for what is deployed in AWS.

## Status

Milestone 1 (skeleton) is in place. It includes the models and the scheduler with tests. It also has a working timeline, the thought view with pin, archive, snooze and restore, a Markdown editor with a selection-aware format bar and list continuation, Markdown rendering via MarkdownUI with tappable tags that open the tag's timeline, blurred-text and image-gallery blocks, images in thoughts (inline or in galleries; photo library, camera or paste; full-screen viewer), tag parsing with tag timelines (including an Untagged one), settings for the default interval, and an optional daily reminder (local notifications, off by default). Quick capture works from the share sheet (Share > Thought Reps; for Apple Notes, use Share > Export as Markdown to keep formatting); the app imports waiting items on launch and when it returns to the foreground.

Under evaluation: opening a thought requeues it right away. The alternative is an explicit Requeue button on the thought page, so that reading a thought without acting on it leaves it due.

Coming next, per the spec:

- Search
- Export (there is no legacy data import)
