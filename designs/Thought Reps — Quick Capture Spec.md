# Thought Reps — Quick Capture Spec

Status: built for 1.0 (Oct 14, 2026; part of "After launch" item 3 in the Launch Plan, moved up). Device checks below still owed.

## Goal

The Action button (iPhone 15 Pro and later) opens Thought Reps straight into a new, empty thought. That's all.

The user sets it up in iOS Settings → Action Button → Shortcut → Thought Reps → **New Thought**. The same action also shows up in the Shortcuts app and Spotlight, and Siri can run it ("New thought in Thought Reps"). These come free with an App Shortcut.

Out of scope (decided Oct 14, 2026): saving a thought without opening the app ("Add Thought" with a text box), a Control Center / Lock Screen control, widgets, and reading the current page or clipboard. Links keep coming in through the share sheet.

## `NewThoughtIntent`

- An `AppIntent` in the app target: `openAppWhenRun = true`, no parameters, title "New Thought", SF Symbol `square.and.pencil`.
- `perform()` runs in the app and asks `AppNavigation` for a new thought. That opens the same editor sheet as "+".
- **Always empty:** no tag prefill, even if the app was left on a tag's timeline. The request carries `skipsTagPrefill` so `startCapture` skips `captureContext.tag`; the in-app "+" keeps its prefill.
- **Cold launch.** `RootTabView` reacts with `.onChange(of: navigation.newThoughtRequestCount)`, which misses a request made before the view mounts. Add a pending request on `AppNavigation` that the root consumes on appear (or with `initial: true`), so pressing the button when the app isn't running still opens the editor.
- **Already busy.** `requestNewThought` already ignores the request while a sheet or dialog is up (`ModalPresence`), so an open editor with a draft is never replaced. The app just comes to the front.
- **Store didn't open.** If the "Couldn't open your thoughts" screen is showing, the request does nothing.
- It never selects or opens a thought, so no view is recorded and nothing requeues.

## `ThoughtRepsShortcuts` (`AppShortcutsProvider`)

One App Shortcut for `NewThoughtIntent`, with the phrases "New thought in \(.applicationName)" and "Write a thought in \(.applicationName)". Apple requires every phrase to contain `.applicationName`. This App Shortcut is what lists the action under Thought Reps in the Action button settings, so the user doesn't have to build a shortcut.

## Files touched

| Area | Change |
|---|---|
| `ThoughtReps/Intents/NewThoughtIntent.swift`, `ThoughtRepsShortcuts.swift` | New. Run `xcodegen`. |
| `ThoughtReps/Services/AppNavigation.swift` | `pendingNewThought` + `consumeNewThought()`; `NewThoughtRequest.skipsTagPrefill`. |
| `ThoughtReps/App/RootTabView.swift` | Consume the pending request on appear; skip the tag prefill when flagged. |
| `site-landing/src/content/help.ts` | Short new article "Open a new thought with the Action button" (setup steps, Siri phrase), linked to and from the related writing articles. |

No new target, no model change, no `formatVersion` bump, no network calls, and no change to the privacy manifests or policy.

## Tests

1. **Unit:** a request made before the root appears is consumed exactly once; a request while `ModalPresence` is up is dropped; a flagged request starts with no tag.
2. **Device checks:**
   - the Action button opens an empty editor from the Home Screen, from inside another app, from inside Thought Reps while you're on a tag's timeline, and on a cold launch
   - pressing it with the editor already open keeps your draft
   - "New thought in Thought Reps" works with Siri

## Effort

About 2–3 hours: an hour for the code and tests, then the help article and a device check.

## Later

- "Add Thought": a text box over the current app that saves without opening Thought Reps, written to the App Group inbox like the share extension.
- A Control Center / Lock Screen control (needs a widget extension target).
- A "due today" widget (needs a thought snapshot in the App Group; privacy look first).
