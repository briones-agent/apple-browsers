# Project Log

**Project:** iOS — Hide / dismiss items in the Settings "Next Steps" section
**Asana (primary task):** Quick Win: iOS: Hide next steps in mobile browser settings — https://app.asana.com/1/137249556945/project/1214749231578703/task/1213808191087548

## Current handoff
- **Goal:** Make items in the iOS Settings **"Next Steps"** section dismiss automatically once the user has acted on them, so the section stops feeling "stuck" (items currently never go away even after the setting is changed).
- **Status:** DONE — all four tasks committed atomically on `bartosz/next-steps` and verified (full app compiles; 10 Next Steps unit tests pass). Nothing pushed.
- **Completed:** #1/#2 dismissal (`a190ece03a`) · animation (`33dd09c07f`) · 14-day Hide button (`2580af341e`) · debug screen (`db0f3184bb`).
- **Next:** (optional) manual simulator smoke-test of the Hide button + animations (the new debug screen makes this quick); push + open PR when ready. Awaiting user decision on whether to commit / gitignore `project_log.md` + `project_lessons/` (currently untracked).
- **Blockers:** None.

### Verification done
- `xcodebuild test -scheme "iOS Unit Tests" -destination 'id=E4AA621C…' (iPhone SE 2nd gen, iOS 18.6) -only-testing:UnitTests/SettingsNextStepsDismissalTests` → **BUILD + TEST SUCCEEDED**, 5/5 passing.
- NOTE the test **target name is `UnitTests`** (not `DuckDuckGoTests`, which is only the folder/group name). Use `-only-testing:UnitTests/...`.

### Manual smoke-test still to do (in simulator)
- Fresh install → open Settings → "Next Steps" shows all 4 rows (3 on iPad — no address bar row).
- Change address bar to bottom → pop back → address bar row gone immediately.
- Enable Voice Search → pop back → voice search row gone immediately.
- Tap "Add to Dock" / "Add Widget" → rows REMAIN (dismiss only +1 day later; verify by back-dating the stored timestamp or waiting).
- When all rows gone → the whole "Next Steps" header disappears.

### Files changed
- `iOS/DuckDuckGo/SettingsViewModel.swift` — new `@Published shouldShowAddToDockNextStep`/`shouldShowAddWidgetNextStep`; computed `shouldShowSetAddressBarPositionNextStep`/`shouldShowEnableVoiceSearchNextStep`/`shouldShowNextStepsSection`; `updateNextStepsVisibility()` (called from `initState()`); `recordAddToDockNextStepTapped()`/`recordAddWidgetNextStepTapped()`; static `hasTapDismissalElapsed(...)`; 3 new `Constants` keys.
- `iOS/DuckDuckGo/SettingsNextStepsView.swift` — each cell gated on its visibility flag; dock/widget taps recorded; whole `Section` gated on `shouldShowNextStepsSection`.
- `iOS/DuckDuckGoTests/SettingsNextStepsDismissalTests.swift` — NEW; 5 tests for the +1-day helper.
- `iOS/DuckDuckGo-iOS.xcodeproj/project.pbxproj` — registered the new test file (4 entries; UUIDs prefixed `DDCC0FF1…`).

## Implementation map (iOS)
- **View:** `iOS/DuckDuckGo/SettingsNextStepsView.swift` — 4 hardcoded cells (Add to Dock button; Add Widget NavigationLink; Address Bar NavigationLink, already gated `!isPad`; Voice Search NavigationLink). No item model.
- **View model:** `iOS/DuckDuckGo/SettingsViewModel.swift`. `@Published state` (line ~170), `keyValueStore: ThrowingKeyValueStoring` (line ~157). Mirror the existing "Complete Setup" dismissal (`updateCompleteSetupSectionVisiblity()` ~1316, keys in `Constants` ~1411, `shouldShowSetAsDefaultBrowser` ~266).
- **Detection signals (all already in `state` or persistable):**
  - Address bar changed → `state.addressBar.position != .top` (default is `.top`; binding writes `state.addressBar.position` at line 346, so it updates live).
  - Voice search on → `state.voiceSearchEnabled` (binding writes it at 912/922, updates live).
  - Dock/Widget → no system signal → persist first-tap timestamp, hide after +1 day.

## Scope (confirmed with user 2026-07-15)

**IN SCOPE:**
1. **"Set your address bar position"** and **"Enable Voice Search"** rows → dismiss the row **if the user taps in and actually changes the setting** on the subsequent page.
2. **"Add app to your dock"** and **"Add widget to home screen"** rows (iOS-only) → dismiss **+1 day after the user taps the option**. The 1-day delay is intentional: it gives the user time to revisit the tutorial while making the change.

**OUT OF SCOPE (deferred, revisit last):**
3. The **"Hide" button** next to the "Next Steps" header (shown 14 days after install) that hides the whole section.
   - Reason (user): iOS Settings uses a stock table view; no other section has a "Hide" button, so the implementation approach is unclear. Defer until items #1 and #2 are done, then reassess.

**Explicit boundaries:**
- This task is ONLY the **"Next Steps"** section (bottom of Settings). The **"Complete Your Setup"** section (top) and the **Set-as-Default** row are a *separate* sibling Quick Win — https://app.asana.com/1/137249556945/project/1214749231578703/task/1213808191087550 (do not touch here).
- "Add to dock" / "Add widget" are **iOS-only** items (that's why the Android version of this work omits item #2).

## Decisions

### 2026-07-15 — Defer the "Hide" button (item #3)
- **Decision:** Ship items #1 and #2 (auto-dismiss on interaction) first; leave the 14-day "Hide" button out of scope for now.
- **Why:** iOS Settings is a stock `UITableView`-style screen with no precedent for a per-section "Hide" control; approach/design is unclear and would balloon a Quick Win. Auto-dismissal delivers most of the user value (items that "stick" are the core complaint).
- **Consequences:** The section can still linger for users who never touch remaining items. Acceptable for the Quick Win; the button is tracked to revisit after #1/#2 land.

### 2026-07-15 — Implementation approach
- **Address bar & voice search items = computed properties** derived from `state` (`state.addressBar.position == .top`; `!state.voiceSearchEnabled`). Because their sub-view bindings write back to `@Published state`, the rows disappear live the moment the user changes the setting and pops back — no observers/notifications needed.
- **Dock & widget items = persisted first-tap timestamp** in `keyValueStore` (stored as `Double`, `timeIntervalSinceReferenceDate`), recomputed by a new `updateNextStepsVisibility()` called from `initState()` (every Settings open). Only the FIRST tap is recorded, so the +1-day window anchors to initial engagement. Dock tap recorded in the button action; widget tap recorded via the destination's `.onAppear`.
- **The +1-day math lives in a pure `static func hasTapDismissalElapsed(tappedAt:now:interval:)`** on `SettingsViewModel` — unit-testable in isolation (the full VM is impractical to instantiate in tests; the existing Complete Setup dismissal is itself untested).
- **Auto-hide the whole section when empty:** the `Section` renders only if ≥1 item is visible (`shouldShowNextStepsSection`), avoiding a dangling "Next Steps" header. This is a natural, softer version of the deferred Hide button — the section quietly goes away once everything is done.
- **No iOS-version gate and no feature flag.** (Complete Setup is `iOS 18.2`+/flag-gated for unrelated reasons; Next Steps ships to everyone.) Revisit if remote gating is later requested.
- **No pixels added.** Existing `settingsnAddAppToDock`/`settingsnAddWidget` pixels are defined but unused; ACs don't require analytics. Left as-is to keep the change focused.

## Task 3/4/2 — implementation specs (from recon, for continuity)

### Task 3 — animation (implemented)
- Converted `shouldShowSetAddressBarPositionNextStep` / `shouldShowEnableVoiceSearchNextStep` from computed props to stored `@Published` bools; `updateNextStepsVisibility()` → `refreshNextStepsVisibility(animated:)` (wraps mutations in `withAnimation` when animated). `initState()` calls it with `animated:false`; each pushed sub-view (`SettingsAppearanceView`, `SettingsAccessibilityView`) calls `refreshNextStepsVisibility(animated:true)` from `.onDisappear`, so the finished row animates out on pop-back. (`withAnimation` already used in this file at `updateRecentlyVisitedSitesVisibility`.)

### Task 4 — 14-day Hide button (next)
- **Install date:** `StatisticsUserDefaults().installDate: Date?` (`iOS/Core/StatisticsUserDefaults.swift:61`), `nil` before ATB recorded. Reach it directly (as `AppUserDefaults.swift:405` does) — not injected into the VM.
- **Static helper (testable, sibling to `hasTapDismissalElapsed`):** `hasInstallGracePeriodElapsed(installDate:now:requiredInterval:) -> Bool` (guard nil → false; `now.timeIntervalSince(installDate) >= requiredInterval`).
- **New `Constants`:** `nextStepsSectionHiddenKey = "com.duckduckgo.settings.next-steps.section-hidden"`; `nextStepsHideMinimumInstallAge: TimeInterval = 14*24*60*60`.
- **VM:** `@Published var nextStepsSectionHidden = false`; read it in `refreshNextStepsVisibility` (`(try? keyValueStore.object(forKey:) as? Bool) ?? false`); computed `shouldShowNextStepsHideButton` (uses the static helper + `StatisticsUserDefaults().installDate`); fold `!nextStepsSectionHidden &&` into `shouldShowNextStepsSection`; `func hideNextStepsSection()` sets key + flag.
- **View:** header becomes `HStack { Text(UserText.nextSteps); Spacer(); if viewModel.shouldShowNextStepsHideButton { Button … } }` modeled on `YouTubeAdBlockPicker.swift:64-76`; use the `eyeClosed` glyph (`DesignSystemImages.Glyphs.Size24.eyeClosed`, as `SettingsCompleteSetupView.swift:50-58`) to avoid header uppercasing, or `.textCase(nil)` for a text label. New `UserText.nextStepsHide` near `UserText.swift:1592`.
- **Tests:** add `hasInstallGracePeriodElapsed` cases to `SettingsNextStepsDismissalTests.swift` (nil→false; just-before→false; exactly/after→true; clock-before-install→false).

### Task 2 — debug menu (last)
- Data-driven: add ONE entry to `screens: [DebugScreen]` in `iOS/DuckDuckGo/DebugScreensViewModel+Screens.swift:36`. `DebugScreen` cases: `.action(title:,closure)`, `.view(title:,closure)`, `.controller(...)` (`DebugScreen.swift:64-66`); `Dependencies.keyValueStore` at `DebugScreen.swift:49` (same store as the VM).
- Template: `.action(title: "Reset Settings > Complete Setup", …)` at `DebugScreensViewModel+Screens.swift:66-70` clears `SettingsViewModel.Constants.*` keys via `try? d.keyValueStore.set(nil, forKey:)`. Actions auto-toast "<title> - DONE". `SettingsViewModel.Constants` is reachable from debug code (same module).
- Plan: a `.view(title: "Next Steps", { d in SettingsNextStepsDebugView(keyValueStore: d.keyValueStore) })` sub-screen with: (a) Reset state (set all next-steps keys incl. `nextStepsSectionHiddenKey` to nil → rows reappear); (b) Expire tap timers (back-date dock/widget timestamps to `now - interval - 1` → dismiss on next open); (c) satisfy the 14-day gate by back-dating install date: `StatisticsUserDefaults().installDate = Calendar.current.date(byAdding: .day, value: -15, to: Date())` (pattern `OnboardingDebugView.swift:240-244`), or a persisted debug bool in `AppUserDefaults.DebugKeys` (`:131`, accessor `:681`).
- NOTE: effects apply on next Settings (re)open (visibility recomputed in `refreshNextStepsVisibility` from `initState`).

## Asana context (reference — so this need not be re-fetched)

**Task hierarchy**
- Epic: **[iOS & Android] Make options in next steps in settings disappear once changed** — https://app.asana.com/1/137249556945/project/715106103902962/task/1211757826678870 (completed; lives in "O-A Meta Project (Mobile Browser Experience)")
  - Investigation: **Investigate hiding next steps in mobile browser settings** — https://app.asana.com/1/137249556945/task/1211760222288865 (completed; DRI: Chris Thelwell). Holds the reviewed "Proposal" that became the ACs.
    - **iOS Quick Win (THIS TASK):** https://app.asana.com/1/137249556945/project/1214749231578703/task/1213808191087548
    - Android Quick Win (DONE): https://app.asana.com/1/137249556945/project/715106103902962/task/1213796904982004
    - Project Estimation: https://app.asana.com/1/137249556945/task/1213760199857404

**Why now / motivation**
- Users complain that Next Steps items "cannot be gotten rid of no matter what options they choose," making the section feel incomplete. Internal feedback (incl. a report from yegg) drove it. Ana Capatina also flagged that having both "Complete Your Setup" (top) and "Next Steps" (bottom) is confusing.
- Success criterion (epic): "User no longer complains about the next steps section not updating."

**Sizing**
- T-shirt size **Small**; engineers (Marcos, Brindy) confirmed **~1–2 days engineering** is fine for a Quick-Win-scoped version. Custom fields: Friction 2, Impact 2, Quick Win Score 4.

**Android reference implementation (DONE — use as behavior blueprint)**
- Task: https://app.asana.com/1/137249556945/project/715106103902962/task/1213796904982004
- PR: **duckduckgo/Android #8281 — "Make Next Steps section in Settings dismissable"** (approved/merged): https://github.com/duckduckgo/Android/pull/8281
- Android scope = items #1 and #3 only (no dock/widget, since those are iOS-only).
- **How Android detects "changed" (item #1):** captures the setting value before the user navigates into it and compares on return — `SettingsViewModel.refreshNextStepsDismissals()` compares `omnibarType` (address bar) and `voiceSearchAvailability.isVoiceSearchAvailable` before/after. If different → dismissed.
- **Android persistence:** plain booleans in `SettingsSharedPreferences`: `nextStepsAddressBarDismissed`, `nextStepsVoiceSearchDismissed`, `nextStepsSectionHidden`. No feature flag.
- **Hide button (item #3, deferred):** shown when `appInstallStore.daysInstalled() >= 14`.
- **⚠️ "+1 day after tap" (item #2 — dock/widget) has NO Android equivalent** — it's iOS-only. Must be designed for iOS: record a tap timestamp per item, hide once `now - tappedAt >= 1 day`. (Android instead hid its widget item when widgets were actually installed — a signal iOS *could* also use via `WidgetCenter`, but the iOS AC specifies the +1-day-after-tap rule, so follow that.)

**Proposal / ACs verbatim (from investigation task)**
1. Set address bar position and Enable voice search → Dismiss if user taps and changes the setting on the subsequent page.
2. Add to dock and add widget → Dismiss +1 day after user taps these options (gives time to revisit tutorials).
3. Add a "Hide" button alongside "Next Steps" after 14 days since install (14 = starting value, open to change) → tapping hides the whole Next Steps section.

**Key people**
- Chris Thelwell — product DRI, drove proposal. Robin Schlinkert & Peter Dolanjski — approved. Marcos & Brindy — engineering estimate. Ana Capatina — raised the two-confusing-sections feedback.

## Open questions
1. Persistence location for per-item "dismissed" flag + timestamp for the "+1 day" rule (KeyValueStore vs AppUserDefaults — being determined).
2. Is a feature flag expected for this? (Check PrivacyConfig / FeatureFlag pattern; likely not required for a Quick Win, confirm.)
3. Design for the deferred Hide button (Chris offered to produce one) — not needed until #3 is revisited.

## Recent progress

### 2026-07-15
- Gathered complete Asana context (epic, investigation, 3 sibling Quick Wins, Project Estimation, originating feedback task). Confirmed Goal section = acceptance criteria.
- User confirmed scope: items #1 and #2 in; Hide button (#3) deferred.
- Recon mapped the iOS Next Steps feature; confirmed the "Complete Setup" dismissal is the template to mirror and that address-bar/voice-search bindings write back to `@Published state`.
- Implemented items #1 (address bar / voice search → hide on change, via computed props) and #2 (dock / widget → hide +1 day after first tap, via persisted timestamp). Whole section auto-hides when empty.
- Added `SettingsNextStepsDismissalTests` and registered it in the (non-synchronized) pbxproj.
- Verified: `xcodebuild test` (iOS Unit Tests scheme, iPhone SE 2nd gen / iOS 18.6, `-only-testing:UnitTests/SettingsNextStepsDismissalTests`) → BUILD + TEST SUCCEEDED, 5/5 passing, 0 compile errors. (Two earlier failures were bad xcodebuild args — unavailable simulator, then wrong test-target name — not code issues.)
- Committed #1/#2 as `a190ece03a`; user confirmed it works in the app.
- Added, per user request: row-removal animation (`33dd09c07f`), 14-day Hide button + tests (`2580af341e`), and a Next Steps debug screen (`db0f3184bb`). Tasks 4 & 2 were implemented by delegated subagents; each verified (full app compiles, 10 Next Steps tests pass) and committed atomically.
- `project_log.md` + `project_lessons/` remain untracked pending user decision on committing/gitignoring them.
