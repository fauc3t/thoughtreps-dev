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
- A free Apple ID also works, with 7-day installs and no iCloud.

## Everyday commands

| Task | Command |
| --- | --- |
| Regenerate the Xcode project (after pulling, or adding or removing files) | `xcodegen` |
| Run the app | ⌘R in Xcode |
| Run the tests in Xcode | ⌘U |
| Run the tests from the terminal | `xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'` (names from `xcrun simctl list devices available`) |

`ThoughtReps.xcodeproj` is generated from `project.yml` and gitignored, so edit `project.yml` rather than the project's build settings.

Debug builds seed sample thoughts on first launch. Settings > Developer can add more or delete everything.

## Running on an iPhone

1. Connect the phone and turn on Developer Mode (Settings > Privacy & Security).
2. Pick the phone as the run destination in Xcode and press ⌘R.
3. The first time, trust the developer certificate under Settings > General > VPN & Device Management.

With a paid developer account the install lasts a year.
