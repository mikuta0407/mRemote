# mRemote

An RDP client for iPadOS/iOS, and for macOS through Mac Catalyst. Its reason
to exist is the Japanese keyboard: the Eisu and Kana keys on a physical JIS
keyboard are sent to Windows as Muhenkan and Henkan instead of being consumed
by the system's input switcher.

This is a personal project, developed by one person against one iPad, one
keyboard and one Windows host. See
[`docs/README.md`](docs/README.md) for the design documents and for the
verification scale everything here is held to.

## Layout

The repository is one product, so the tree is organised by role rather than by
platform.

| Path | Contents |
|---|---|
| `mRemote.xcodeproj`, `App/` | The app: the connection list, the profile editor, settings and the full-screen session workspace. `AppTests/` and `AppUITests/` sit beside it. |
| `Packages/mRemoteKit/` | The app layers that need no UIKit, so they build and test on the development host: `SessionCore`, `Persistence`, `AppleAdapters`, `RDPProtocol`. |
| `bridge/` | The C ABI over FreeRDP. Opaque handles only; no FreeRDP type reaches Swift. |
| `scripts/`, `config/`, `ThirdParty/`, `artifacts/` | Reproducible builds of the pinned native dependencies, their lock file, notices and SBOM, and the generated XCFrameworks. |
| `tools/KeyEcho/` | A Win32 recorder that logs what scancodes actually arrived at Windows. |
| `tools/Phase0Harness/` | The UIKit/Metal spike app. Now a fixture for physical input checks rather than product code. |
| `docs/` | Requirements, architecture, input design, UI flow, data and security, test plan, roadmap. |
| `phase0/` | The Go/No-Go spike: its decision, records and notes. |

## Status

Phase 0 is closed with a `GO` for the personal baseline: FreeRDP runs on
device, a real NLA/TLS session renders a desktop, and Eisu/Kana reach Windows
as Muhenkan/Henkan without iPadOS consuming them. See
[`phase0/README.md`](phase0/README.md).

Phase 1 meets its exit criteria: the app runs end to end against
`FakeRemoteSession`, passwords never reach the profile document, the schema is
versioned with a tested migration chain, and a second protocol would be added
by registering a factory rather than by changing a call site.

Phase 2 connects the real thing: `RDPRemoteSession` runs FreeRDP behind the
same `RemoteSession` interface, the workspace draws the desktop on a Metal
surface fed by dirty regions, and a server certificate is reviewed with its
fingerprint rather than accepted quietly. Its remaining exit criteria are the
ones that need a machine rather than a test: thirty minutes against the
Windows host, and the bridge sanitizer stress carried over from Phase 0. See
[`docs/roadmap.md`](docs/roadmap.md).

Phases 3 to 6 are implemented ahead of their device checks, verified with
automated tests and on the iPad simulator only: `GCKeyboard` arbitration with
quarantine and the remote cursor (3), multiple sessions with a switcher and
automatic reconnect (4), focused-session audio and two-way clipboard text (5),
and the software keyboard with local/host IME modes and an extended key bar
(6). Each phase's table in [`docs/roadmap.md`](docs/roadmap.md) marks what still
needs the iPad and the Windows host.

The Mac build is the same app through Mac Catalyst. Each connection opens in
a window of its own beside the list, the Mac's keyboard and mouse go to
Windows as they are (⌘ is the Windows key, ⌥ is Alt; 英数/かな are
Muhenkan/Henkan; only ⌘Q, ⌘H, ⌘M, ⌘\` and ⌃⌘F stay with the Mac), and the
iPad-only parts - the software keyboard, the laptop deck, the hinge - are left
out. Text and images on the clipboard follow the user both ways without the
session menu. It has been checked against the Windows host from a macOS 26 VM; see
[`docs/input-design.md`](docs/input-design.md) section 12.

A connection can also be marked as reaching a Mac running
[macos-rdp-server](https://github.com/mikuta0407/macos-rdp-server). It then
offers the Mac RDP eXtensions ([macrdpx](https://github.com/mikuta0407/macrdpx),
the `external/macrdpx` submodule): once the server agrees, keys go as Mac keys
with their exact modifiers (⌘ stays ⌘, Fn, left/right), the pointer and the
trackpad's pixel scrolling with momentum go natively, and the stream quality
(frame rate and bit rate) is chosen per connection - automatically lower on
cellular - and changeable from the session menu. The server shows the Mac's
own screen, at Retina pixels for a Retina client. Any other server stays
plain RDP; see
[`docs/input-design.md`](docs/input-design.md) section 13.

## Install

**macOS** (Apple silicon, macOS 14 or later), with Homebrew:

```sh
brew install --cask mikuta0407/apps/mremote
```

The Mac app is ad-hoc signed and not notarized; the cask removes the
quarantine attribute so it opens. It keeps passwords and approved
certificates in the login keychain, and after an update macOS may ask once to
let the new build read them.

**iPadOS / iOS**: each [release](https://github.com/mikuta0407/mRemote/releases)
carries an unsigned IPA (`mRemote-<version>-ios-unsigned.ipa`). Install it with
[LiveContainer](https://github.com/LiveContainer/LiveContainer), or sign it
yourself.

Releases are made with `scripts/release.sh vX.Y.Z`, which builds both, creates
the GitHub release and updates the cask in
[mikuta0407/homebrew-apps](https://github.com/mikuta0407/homebrew-apps).

## Build and test

Clone with `--recurse-submodules` (or run `git submodule update --init`):
the bridge compiles `external/macrdpx`.

The app target links the generated `artifacts/FreeRDP.xcframework`,
`artifacts/mRemoteRDPBridge.xcframework` and `artifacts/mRemoteSSH.xcframework`,
which are ignored by git and have to be built once before the app will link. `Packages/mRemoteKit` deliberately
does not declare them, so `swift test` works in a fresh clone with no native
build; the app does not.

```sh
# The app, its unit tests and the end-to-end UI test
xcodebuild test -project mRemote.xcodeproj -scheme mRemote \
  -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)'

# The Mac app (Mac Catalyst, Apple silicon)
xcodebuild build -project mRemote.xcodeproj -scheme mRemote \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64'

# Host-testable app layers
swift test --package-path Packages/mRemoteKit

# Phase 0 harness logic
swift test --package-path tools/Phase0Harness

# C bridge contract tests
cmake -S bridge -B /tmp/mremote-bridge -DBUILD_TESTING=ON -DMR_BRIDGE_BACKEND=unavailable
cmake --build /tmp/mremote-bridge && ctest --test-dir /tmp/mremote-bridge
```

The active toolchain must be a full Xcode rather than the Command Line Tools,
otherwise the Swift test targets cannot resolve XCTest. Prefix with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if
`xcode-select -p` points at `/Library/Developer/CommandLineTools`.

Building the native dependencies from source is documented in
[`phase0/README.md`](phase0/README.md). In short:

```sh
scripts/build-freerdp-xcframework.sh
scripts/build-rdp-bridge-xcframework.sh
scripts/build-ssh-xcframework.sh      # libssh2 + the SSH bridge, on FreeRDP's OpenSSL
```

The SSH terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
as a Swift package (exact version, `Package.resolved` is committed). Two
things follow from it: its Metal shaders need Xcode's Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`, once), and command-line builds
pass `-skipPackagePluginValidation` for its build-info plugin.

SSH has tests of its own: `bridge/ssh/README.md` (the C bridge against a
throwaway loopback sshd), and `bridge/ssh/tests/run_live_app_tests.sh` /
`run_live_ui_tests.sh` (the app in a headless Simulator against one).

Both XCFrameworks carry three slices: `ios-arm64`, `ios-arm64-simulator` and
`ios-arm64-maccatalyst`. An artifact built before the Mac slice existed has
to be rebuilt, or the Mac build will not link.

The Mac app keeps passwords and approved certificates in the data-protection
Keychain when it can: macOS only opens that to an app whose provisioning
profile grants a Keychain access group (`config/mRemote-maccatalyst.entitlements`;
automatic signing fetches the profile and registers the Mac, but a free team's
profile expires after seven days). An ad-hoc signed build - the released one -
has no profile, so at launch it finds that it cannot write there (-34018) and
uses the login keychain instead (`KeychainStore`).

The XCFrameworks' Mac slice is arm64 only, so a Release build (which is
universal by default) is built with `ARCHS=arm64`.

## License

[MIT](LICENSE). Dependency licenses and the SBOM are under [`ThirdParty/`](ThirdParty/).
