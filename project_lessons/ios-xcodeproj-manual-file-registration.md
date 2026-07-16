# New files in `iOS/DuckDuckGo-iOS.xcodeproj` must be registered manually in project.pbxproj

## Lesson
`iOS/DuckDuckGo-iOS.xcodeproj` does NOT use Xcode's file-system–synchronized groups
(`grep -c PBXFileSystemSynchronizedRootGroup project.pbxproj` → `0`). Creating a `.swift`
file on disk is not enough — it won't build until it's added to `project.pbxproj` in **four**
places, each with matching UUIDs:
1. `PBXBuildFile` section — `<buildUUID> /* File.swift in Sources */ = {isa = PBXBuildFile; fileRef = <fileUUID> ...};`
2. `PBXFileReference` section — `<fileUUID> /* File.swift */ = {isa = PBXFileReference; ... path = File.swift; sourceTree = "<group>"; };`
3. The owning group's `children = ( … )` list — `<fileUUID> /* File.swift */,`
4. The target's `Sources` build phase `files = ( … )` — `<buildUUID> /* File.swift in Sources */,`

Reliable method: pick an existing sibling file already in the same group + target, `grep -n` its
four entries, and mirror them (this guarantees correct group/target membership). Invent two unused
24-hex-char UUIDs (verify absence with `grep -c`). Capture exact tab indentation with
`sed -n "<line>p" file | cat -te` (macOS `cat` has no `-A`). After editing, validate with
`plutil -lint project.pbxproj` and confirm the fileUUID appears 3× and the buildUUID 2×.

## Why it matters
A new test or source file silently does nothing (test never runs; symbol "missing") if only created
on disk, which looks like a code bug rather than a project-membership gap. Hand-editing pbxproj is
also easy to corrupt; the mirror-a-sibling + `plutil -lint` + reference-count checks make it safe and
reversible (`git checkout` the pbxproj if anything looks off).

## Evidence
Registered `iOS/DuckDuckGoTests/SettingsNextStepsDismissalTests.swift` by mirroring
`AppUserDefaultsTests.swift`'s four entries. `plutil -lint` → `OK`; fileUUID count 3, buildUUID count 2.
`xcodebuild test -scheme "iOS Unit Tests" -only-testing:UnitTests/SettingsNextStepsDismissalTests`
built clean and ran the 5 tests, confirming correct target membership.

## Gotcha: the unit-test TARGET is `UnitTests`, not `DuckDuckGoTests`
`DuckDuckGoTests` is only the folder/group name. The unit-test build target (what the "iOS Unit Tests"
scheme runs, `BlueprintName = "UnitTests"`, product `UnitTests.xctest`) is named **`UnitTests`**. So
`-only-testing:` / `-skip-testing:` must use `UnitTests/<Class>` — `-only-testing:DuckDuckGoTests/…`
fails pre-build with "isn't a member of the specified test plan or scheme". Also pick a simulator that
`xcodebuild` actually lists (its device list is narrower than `xcrun simctl list devices available`);
resolve with `xcodebuild test … -destination 'id=<UDID>'`.

## Related
See also: the app's `SettingsViewModel` is not practically instantiable in unit tests (large
dependency graph; no existing `SettingsViewModelTests`), so testable logic was extracted into a pure
`static func hasTapDismissalElapsed(...)`. Prefer pure static helpers for logic that must be tested.
