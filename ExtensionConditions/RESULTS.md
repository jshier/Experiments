# Compile-time app extension checks: results

Can Swift code know at compile time that it's being built for an app extension? Checked with Xcode 27.3
(27C5020n), Swift 6.4.2, ld 27106.1, iOS 27.3 simulator SDK. `./run.sh` repeats every check (31; `--simulator`
also runs the app); all pass.

## Setup

A JSON-format project (`ExtensionConditions.xcodeproj/project.xcproj`, created with the Xcode MCP's
`XcodeNewProject`/`XcodeNewTarget`, then edited by hand):

| Target | Kind | Notes |
|---|---|---|
| `ExtensionConditions` | app | links and embeds both frameworks, embeds the widget |
| `WidgetExtension` | WidgetKit app extension | links `SharedKit` only |
| `SharedKit` | framework | `APPLICATION_EXTENSION_API_ONLY = YES` (via `SHAREDKIT_EXTENSION_SAFE`, so a run can turn it off) |
| `AppOnlyKit` | framework | app only |
| `Shared/SharedSource.swift` | source file | member of both the app and the widget |

Project-level settings derive two conditions:

```
_APPEX_API_CONDITION_YES = APP_EXTENSION_API          // from APPLICATION_EXTENSION_API_ONLY
_APPEX_PRODUCT_CONDITION_appex = APPEX_PRODUCT        // from WRAPPER_EXTENSION
_EXTENSION_CONDITIONS = $(_APPEX_API_CONDITION_$(APPLICATION_EXTENSION_API_ONLY)) $(_APPEX_PRODUCT_CONDITION_$(WRAPPER_EXTENSION))
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) $(_EXTENSION_CONDITIONS)
```

Every `#if` branch appends a distinct `MARK …` string (over 15 bytes, so it's in `__cstring`, not inline),
and `strings` on each built binary shows which branches were compiled.

## Results

**The compiler gets one flag and nothing visible to code.**
- `clang -fapplication-extension` predefines exactly the same 482 macros as without it.
- `swiftc -application-extension` adds that one frontend argument; `-target` is unchanged. In the Xcode
  build, app and widget both compile with `-target arm64-apple-ios26.0-simulator`; only the widget (and the
  extension-safe SharedKit) gets `-application-extension`. The triple's build settings
  (`SWIFT_PLATFORM_TARGET_PREFIX`, `LLVM_TARGET_TRIPLE_VENDOR`, `LLVM_TARGET_TRIPLE_SUFFIX`) are identical.
- `#if targetEnvironment(applicationExtension)` compiles with no diagnostic and is false, even under
  `-application-extension`; so is any made-up value (`targetEnvironment(notARealEnvironment)`).

**Build settings know.** Widget: `PRODUCT_TYPE = com.apple.product-type.app-extension`,
`WRAPPER_EXTENSION = appex`, `APPLICATION_EXTENSION_API_ONLY = YES`.

**Correction: derive the condition from `WRAPPER_EXTENSION`, not `APPLICATION_EXTENSION_API_ONLY`.**
Extension-safe frameworks set `APPLICATION_EXTENSION_API_ONLY = YES` too, so `APP_EXTENSION_API` is
defined for SharedKit (a framework the app also uses). `APPEX_PRODUCT` is defined only for the widget.

| Binary | Markers |
|---|---|
| app | `SharedSource compiled`; `SharedKit inlinable compiled`, `SharedKit inlinable APP_EXTENSION_API` |
| widget | `SharedSource compiled`, `SharedSource APP_EXTENSION_API`, `SharedSource APPEX_PRODUCT`; the same two SharedKit inlinable markers |
| SharedKit | `SharedKit compiled`, `SharedKit APP_EXTENSION_API` (and its inlinable markers) |

**Shared source files work:** compiled once per target, each with its own conditions. The app-only
`SharedSource.openSettings()` (under `#if !APPEX_PRODUCT`) is in the app's symbols, not the widget's.

**Frameworks can't know their client.** SharedKit is compiled once (one compile command) with its own
conditions. `@inlinable` code doesn't change that: inlined into both the app and the widget, it carries
SharedKit's branch (`APP_EXTENSION_API`, even in the app). The `.swiftinterface` prints only the active
branch of the inlinable body (no `#if` left), so clients building from the interface get it too.

**Availability is the check for library code.**
- The widget calling `@available(iOSApplicationExtension, unavailable)` `SharedKit.openSettings()`: error
  `'openSettings()' is unavailable in application extensions for iOS`. The function is still compiled into
  SharedKit.
- Extension-unsafe API without that annotation in a framework built with
  `APPLICATION_EXTENSION_API_ONLY = YES`: error `'shared' is unavailable in application extensions for iOS`.
- The same call in the shared source file without the `#if`: an error, in the widget's compile.

**Correction: no linker warning any more.** SharedKit built with `APPLICATION_EXTENSION_API_ONLY = YES` has
the Mach-O `APP_EXTENSION_SAFE` flag; without it the flag is gone, but the widget still links it with no
diagnostic. Older linkers warned ("linking against a dylib which is not safe for use in application
extensions"); ld 27106.1 doesn't, also when linking by hand with `clang -fapplication-extension`. So the
reason to set it on a framework is the compile-time check of the framework's own code (and the flag).

**Leaving code out of the extension's binary takes a separate module.** The widget doesn't link AppOnlyKit
(`otool -L`) and has none of its code.

**Runtime:** the app on an iOS 27.3 simulator reports `Bundle.main.bundleURL.pathExtension == "appex"` as
false. (The widget side wasn't run: it needs the widget placed on a home screen.)

## Not tested

- **Swift packages.** `SharedPackage/` is a local package for the same check, but it isn't in the project:
  the JSON format's package product dependency syntax isn't documented, and the parser ignores unknown keys,
  so probing didn't find it. Known so far: a top-level `"packages": [{ "kind": "local", "path":
  "SharedPackage" }]` resolves the package (package entries know `kind`, `path`, `traits`); a target's
  `"dependencies"` take only targets. Adding the package once in Xcode's UI would show the syntax.
- Package traits per client (claimed to apply to the whole graph, not per target).

## Notes on the JSON project format

- New Xcode 27 projects are written as `project.xcproj` (JSON with trailing commas). `xcodebuild` reads it.
- Unknown keys are ignored silently; a known key with the wrong type is an error naming its JSON path, which
  is how to find which keys exist.
- Linking a product: add `"target-membership": ["App/frameworks", { "build-phase": "App/copy/Embed
  Frameworks", "code-sign-on-copy": true, "header-preservation": "remove-on-copy" }]` to its entry in the
  Products group, plus a `{ "kind": "copy", "name": "Embed Frameworks", "bundle-base-path":
  "frameworks-directory" }` build phase, and the target in `"dependencies"`.
- Xcode lost the app's scheme after the file was edited on disk while open (xcodebuild autogenerates it).
  Close the project in Xcode before editing the file.
