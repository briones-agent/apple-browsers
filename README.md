# DuckDuckGo Apple Browsers + React Native

This is an experimental fork of the official [DuckDuckGo Apple Browsers](https://github.com/duckduckgo/apple-browsers) monorepo with the sole purpose of testing brownfield support for Expo and React Native in large native-first codebases. Its commits serve as a reference for anyone interested in integrating React Native into an existing iOS app, especially those that don't want to refactor the whole project structure to accommodate React Native.

This project uses Expo's brownfield isolated approach.

## Integration steps

Check commits for detailed steps, full instructions can be found in the [expo-brownfield documentation](https://docs.expo.dev/brownfield/overview/).

1. **Create the Expo app**: Run `npx create-expo-app expo-app --template default@canary` to set up a new Expo app (SDK 57).
2. **Install expo-brownfield**: Add `expo-brownfield` to your project (`npx expo install expo-brownfield`) and build a prebuilt Swift Package with `npx expo-brownfield build:ios --release --package`.
3. **Add React Native view**: Consume the prebuilt Swift Package as a remote SPM dependency and present the React Native screen from the existing app. This fork depends on a shared, pre-built package ([briones-agent/expo-brownfield-shared-ios](https://github.com/briones-agent/expo-brownfield-shared-ios)) so the artifact is built once and reused across many host apps.

The iOS app (`iOS/DuckDuckGo-iOS.xcodeproj`, `iOS Browser` scheme) is UIKit: React Native is bootstrapped from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, and the floating "Expo" button opens the RN screen on its own `UIWindow`.

> **Building this fork:** run `git submodule update --init --recursive`. The private `DuckSansFont` SPM package has been removed (external contributors can't resolve it; its usage is `#if canImport`-guarded so the app falls back to the system font). Copy `iOS/Configuration/DuckDuckGoDeveloper.xcconfig` to `iOS/Configuration/ExternalDeveloper.xcconfig`. Build against a concrete simulator destination (the `fix_libswiftWebkit_simulator.sh` build phase needs `TARGET_DEVICE_OS_VERSION`).

<details>
<summary>DuckDuckGo Apple Browsers</summary>

# DuckDuckGo Apple Browsers

This repo contains the source code for the DuckDuckGo iOS and macOS browsers, and the libraries that are shared between them to provide cross-platform features.

## Building

### Submodules

We use submodules, so you will need to bring them into the project in order to build and run it:

Run `git submodule update --init --recursive`

### External contributors: Duck Sans package

The project depends on a private `DuckSansFont` Swift package that ships our licensed Duck Sans typeface. The repository is private, so building a fork without access will fail at SPM resolution. To build as an external contributor, remove the package before building:

1. Open `iOS/DuckDuckGo-iOS.xcodeproj` (or the workspace) in Xcode.
2. Select the project in the Project Navigator, then open the **Package Dependencies** tab.
3. Select **DuckSansFont** and click the **−** button to remove it. The app will fall back to the system font at runtime.
4. Clean and rebuild the project.

### iOS developer details

If you're not part of the DuckDuckGo team, you should provide your Apple developer account id, app id, and group id prefix in an `ExternalDeveloper.xcconfig` file. To do that:

1. Run `cp iOS/Configuration/DuckDuckGoDeveloper.xcconfig iOS/Configuration/ExternalDeveloper.xcconfig`
2. Edit `iOS/Configuration/ExternalDeveloper.xcconfig` and change the values of all fields
3. Clean and rebuild the project

### macOS developer details

If you're not part of the DuckDuckGo team, go to Signing & Capabilities to select your team and custom bundle identifier.

### Dependencies

We use Swift Package Manager for dependency management, which shouldn't require any additional set up.

### SwiftLint

We use [SwifLint](https://github.com/realm/SwiftLint) for enforcing Swift style and conventions, so you'll need to [install it](https://github.com/realm/SwiftLint#installation).

## Terminology

We have taken steps to update our terminology and remove words with problematic racial connotations, most notably the change to `main` branches, `allow lists`, and `blocklists`.

## Contribute

Please refer to the [contributing](CONTRIBUTING.md) doc.

## Discuss

Contact us at https://duckduckgo.com/feedback if you have feedback, questions or want to chat. You can also use the feedback forms embedded within our mobile & desktop apps - to do so please navigate to the app's settings menu and select "Send Feedback".

## License

DuckDuckGo is distributed under the Apache 2.0 [license](https://github.com/duckduckgo/apple-browsers/blob/master/LICENSE.md).

Copyright 2026 DuckDuckGo

Duck Sans is a proprietary typeface created by Fontwerk and licensed to DuckDuckGo under commercial terms. Duck Sans font files are not licensed under the Apache License, Version 2.0, or covered by any open-source license applicable to this repository. You may not extract, copy, distribute, modify, or use Duck Sans font files for any purpose outside of running this software as distributed by DuckDuckGo. Redistributions of compiled builds that include Duck Sans must retain this notice. All rights in and to Duck Sans are reserved by Fontwerk (fontwerk.com).

If you do not have a valid Duck Sans license, remove the DuckSansFont package and the app will fall back to the system font at runtime.

</details>
