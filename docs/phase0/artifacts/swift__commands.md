# TokenBar: build / test / bundle / run with Command Line Tools only

Verified 2026-10-05 on macOS 26.7 (25G229) arm64 with CLT 26.3 (Swift 6.2.4, MacOSX26.2 SDK).
Package settings: swift-tools-version 6.2, platforms .macOS(.v14), swiftLanguageModes [.v6].
The TokenBarApp target uses .defaultIsolation(MainActor.self).
All commands run from the package root.

## 0. Toolchain (required in every shell)
Xcode 27.0 is installed and selected, but its license has not been accepted, so `swift` and `xcrun` exit
with code 69 unless DEVELOPER_DIR points at CLT. ~/.zshenv, ~/.bashrc and ~/.bash_profile already export
it, and both scripts set it if it is missing.

    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    swift --version                  # Apple Swift version 6.2.4

## 1. Build
    swift build                      # debug: ~47 s clean (SDK module cache), ~1 s incremental, 0.1 s no-op
    swift build -c release           # ~38 s clean
    .build/release/tokenbar          # CLI: prints pretty JSON

## 2. Test (swift-testing; CLT has no XCTest)
    scripts/test.sh                  # 9 tests (13 cases) pass; ~42 s clean, ~2 s warm; fails if 0 tests ran

Raw equivalent:

    FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    swift test --scratch-path .build-tests \
      -Xswiftc -F -Xswiftc "$FW" \
      -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xlinker -rpath -Xlinker "$FW"

- Plain `swift test` fails with: error: no such module 'Testing'
- The -F flag must be on the command line. If it is only in Package.swift, `swift test` runs 0 tests and exits 0.
- --scratch-path stops the test flags from forcing a full rebuild of .build/.

## 3. Bundle and ad-hoc sign (output: dist/TokenBar.app)
    scripts/bundle.sh                # release build; ~4 s after a release build
    CONFIG=debug scripts/bundle.sh
    plutil -lint dist/TokenBar.app/Contents/Info.plist
    codesign --verify --strict --verbose=2 dist/TokenBar.app
    codesign -dv --verbose=2 dist/TokenBar.app    # Identifier=dev.tokenbar.TokenBar  Signature=adhoc

`spctl --assess` reports "rejected". That is expected for ad-hoc signing and does not matter for a locally
built app, which has no quarantine attribute.

## 4. Run, inspect, quit
    open dist/TokenBar.app
    pgrep -fl TokenBar.app/Contents/MacOS/TokenBar
    lsappinfo info -only ApplicationType "$(lsappinfo find bundleid=dev.tokenbar.TokenBar)"   # "UIElement" = no Dock icon
    ps -o pid,rss,%cpu -p "$(pgrep -x TokenBar)"; footprint "$(pgrep -x TokenBar)"
    pkill -x TokenBar                # SIGTERM exits at once; applicationWillTerminate does NOT run

The in-app Quit button calls NSApp.terminate(nil), which quits gracefully.

To capture stderr plus framework os_log output (`log show` is blocked inside the agent sandbox):

    open -n --stderr /tmp/tokenbar.err --env OS_ACTIVITY_DT_MODE=YES dist/TokenBar.app

## 5. Bundle smoke test (shows the panel and Settings for ~4 s and takes focus)
    dist/TokenBar.app/Contents/MacOS/TokenBar --selftest; echo $?    # prints SELFTEST PASS, exits 0
    dist/TokenBar.app/Contents/MacOS/TokenBar --label image           # status item style: hstack|label|text|image

## 6. Daily use and cleanup
    ditto dist/TokenBar.app ~/Applications/TokenBar.app     # stable path, needed before using SMAppService; no admin
    rm -rf .build .build-tests dist
    defaults delete dev.tokenbar.TokenBar                   # removes the saved Settings window position

Note: the research run also passed `--cache-path/--config-path/--security-path <scratch> --manifest-cache local`
to SwiftPM so that ~/Library/Caches/org.swift.swiftpm stayed untouched. Normal use does not need these flags.
