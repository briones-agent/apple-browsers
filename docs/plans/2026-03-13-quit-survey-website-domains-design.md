# Quit Survey — "Websites Didn't Work" Domain Selector

**Date:** 2026-03-13
**Status:** Approved

## Problem

"Websites didn't work" is a top quit-survey response, but selecting it gives us no actionable signal about which sites were affected. We want to collect the specific domains to improve debugging and prioritisation.

## Solution

When the user selects the "Websites didn't work" pill, show a multi-select list of the last 5 unique domains from their browser history. If history is empty (e.g. fire window / fire button used), the selector is not shown.

We A/B test two UX layouts, switchable via the debug menu in a single build.

---

## Architecture

### Variant enum

```swift
enum QuitSurveyDomainVariant: String {
    case inline   // domain selector in same view as pills
    case newStep  // domain selector as a separate state/screen
}
```

Persisted in `QuitSurveyUserDefaultsPersistor` under key `quit-survey.domain-variant`. Defaults to `.inline`.

### State machine

Add one new case to `QuitSurveyState`:

```swift
case domainSelection   // Variant B only
```

Flow:
- `.negativeFeedback` → `.domainSelection` (Variant B, "Next" tapped)
- `.domainSelection` → `.negativeFeedback` (back, clears `selectedDomains`)
- `.domainSelection` → quit (submit)

### ViewModel additions

Inject `HistoryCoordinating` into `QuitSurveyViewModel`.

New properties:
- `let recentDomains: [String]` — computed once at init. Sort `history` by `lastVisit` descending, extract unique non-nil `url.host` values, take first 5. Empty = no selector shown.
- `@Published var selectedDomains: Set<String>` — user's domain selection.
- `@Published var activeVariant: QuitSurveyDomainVariant` — loaded from persistor.

New method:
- `toggleDomain(_ domain: String)` — adds/removes from `selectedDomains`.

---

## Views

### Shared component

`DomainToggleRow` — a small reusable view: checkbox + domain label. Used by both variants.

### Variant A — Inline

In `QuitSurveyNegativeView`, when both conditions are true:
- `"websites-didnt-work" ∈ selectedOptions`
- `!recentDomains.isEmpty`

…animate in a labelled section below the pills containing a `DomainToggleRow` per domain. The existing `GeometryReader`-based dynamic height handles the window resize automatically.

Submit button label stays **"Submit and Quit"** in all cases.

### Variant B — New Step

In `QuitSurveyNegativeView`, the submit button reads:
- **"Next"** when `"websites-didnt-work" ∈ selectedOptions && !recentDomains.isEmpty`
- **"Submit and Quit"** otherwise

Tapping "Next" transitions to `.domainSelection`.

`QuitSurveyDomainSelectionView`:
- Back button → `goBack()` → returns to `.negativeFeedback`, clears `selectedDomains`
- Domain toggle list (`DomainToggleRow` per domain)
- **"Submit and Quit"** button

---

## Data & Pixels

### Pixel

Extend the `thumbsDownSubmission` pixel parameters with:

```
affected_domains: String?   // comma-joined selected domains, e.g. "foo.com,bar.com"
                            // nil if no domains selected or no history was shown
```

### Feedback / Asana

In `submitFeedback()`, if `selectedDomains` is non-empty, prepend to the feedback body before sending:

```
Affected domains: foo.com, bar.com

<user's free text>
```

---

## Debug Menu

New **"Quit Survey Variant"** item with options:
- Inline
- New Step

Writes to `QuitSurveyUserDefaultsPersistor`. Gated behind the same internal/debug build flag as `alwaysShowQuitSurvey`.
