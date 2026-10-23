# Doboo

Doboo is a standalone Apple Watch character prototype: a small, soft creature
that feels alive through touch, motion, expression, and haptic feedback.

The first vertical slice deliberately excludes health data and long-term pet
systems. It tests the core sensation first: press or drag anywhere on the watch
screen and Doboo dents toward the contact, stretches, follows the finger, changes
expression, and springs back with haptic feedback when released.

![Doboo running on watchOS](Screenshots/doboo-watch.png)

## Build

- Xcode 26 or later
- watchOS 11 or later
- Generate the project with `xcodegen generate`.
- Build with `xcodebuild -project Doboo.xcodeproj -scheme Doboo -sdk watchsimulator build`.
- Run the platform-independent model tests with `swift test`.

### Windows model development

`DobooCore` and its tests can run on Windows with Swift 6.0 or later, MSVC x64
build tools, and a Windows SDK. See the [Swift Windows prerequisites](https://www.swift.org/install/windows/).
The watchOS app, SwiftUI rendering, gestures, and haptics require Mac/Xcode and
remain unverified by these model tests.

For the local Swift 6.4.1 setup under `%LOCALAPPDATA%\Programs\Swift`, run from
the repository in PowerShell:

```powershell
. .\scripts\Enter-Swift.ps1
swift test
swift build -c release
```

The script changes only the current process environment. Use `-SwiftRoot` and
`-SwiftVersion` if your toolchain location or version differs. No third-party
Swift packages or package-registry login are required.

## Project boundary

Doboo and `squeeez!` are separate products and separate repositories.
`squeeez!` may be studied as a reference for soft-body feel, squash-and-stretch,
and feedback timing, but its code, assets, product scope, and Git history do not
belong to Doboo without a separate, licensed integration.

The UI is native SwiftUI and drawn entirely in code so deformation stays live at
watch scale without shipping borrowed art or code from another product.

## Local signing configuration

The public project leaves `DEVELOPMENT_TEAM` empty. Simulator builds and core
tests do not require a personal development team. Signed device builds require
your own Apple development team and matching provisioning profiles.

For a direct Xcode build, select your team in Signing & Capabilities or pass
`DEVELOPMENT_TEAM=<YOUR_TEAM_ID>` to `xcodebuild`. For a generated project, set
`settings.base.DEVELOPMENT_TEAM` in your local `project.yml`, then run
`xcodegen generate`. Keep the personal signing values out of commits.

If this revision includes `scripts/build_device.py`, configure the local project
before running it: that tool reads Release settings directly from the Xcode
project, so a shell environment variable or command-line override alone does not
configure it. 
