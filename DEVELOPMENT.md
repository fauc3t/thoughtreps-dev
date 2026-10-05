# Development

## First-time setup

Requires macOS with Xcode 16 or later (iOS 18+ deployment target) and a paid Apple Developer account signed in to Xcode (Xcode > Settings > Accounts).

```sh
cd ~/dev/thoughtreps-dev
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen && open ThoughtReps.xcodeproj
```

- `Config/Local.xcconfig` is gitignored. Set `DEVELOPMENT_TEAM` to your Team ID, which is listed under your team in Xcode > Settings > Accounts.
- If Xcode says the bundle ID is unavailable, also set `TR_BUNDLE_ID` there to something unique, such as `com.yourname.thoughtreps`.
- On a device, your team needs the App Group `group.<bundle id>` for the share extension (App ID `<bundle id>.share`). Automatic signing usually registers both; if not, add the group under Signing & Capabilities or at developer.apple.com. Simulator builds work without a team.
- A free Apple ID also works, with 7-day installs and no iCloud.

## Everyday commands

| Task | Command |
| --- | --- |
| Regenerate the Xcode project (after pulling, or adding or removing files) | `xcodegen` |
| Run the app | ⌘R in Xcode |
| Run the tests in Xcode | ⌘U |
| Run the tests from the terminal | `xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'` (names from `xcrun simctl list devices available`) |

`ThoughtReps.xcodeproj` is generated from `project.yml` and gitignored, so edit `project.yml` rather than the project's build settings.

The share extension (`ThoughtRepsShare`) hands thoughts to the app through an `Inbox/` folder in the App Group; `InboxImporter` imports it at launch and on foreground. Info.plists and entitlements are generated from `project.yml` and gitignored, so run `xcodegen` before building a fresh clone. After the first install, "Thought Reps" may not appear in the share sheet until the app has been launched once, or enabled under the share sheet's More / Edit Actions.

Take Photo needs a real device; the simulator has no camera. Photo Library and Paste Image work in the simulator.

Debug builds seed sample thoughts on first launch. Settings > Developer can add more or delete everything.

To try the daily reminder, enable it in Settings and set the time a minute or two ahead, then background the app (the simulator shows banners too). Reminders are rescheduled on foreground and background, so they only reflect due thoughts as of the last time the app was active.

Debug builds also run `IntegrityChecker` over the whole store at launch and log any violations via `os.Logger` (subsystem `com.thoughtreps`). It never repairs or crashes, so a logged violation means a bug in a store write; fix the write rather than the data.

Before launch, a schema change means regenerating `ThoughtRepsTests/Fixtures/default.store`; the steps are in `ThoughtRepsTests/Fixtures/README.md` (`FixtureGenerator` runs only when `TEST_RUNNER_GENERATE_FIXTURE_TO` is set).

## Running on an iPhone

1. Connect the phone and turn on Developer Mode (Settings > Privacy & Security).
2. Pick the phone as the run destination in Xcode and press ⌘R.
3. The first time, trust the developer certificate under Settings > General > VPN & Device Management.

With a paid developer account the install lasts a year.
