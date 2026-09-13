# Ghostty embedding assessment (2026-09-13)

The user asked whether embedding Ghostty would work better. This round only read the official material and the source; nothing was built, integrated or benchmarked, and 0.2.0 continues to use SwiftTerm 1.15.0. The recommendation is to build a separate prototype after the release, rather than inferring the real effect from the name of an architecture.

## The current official interfaces

The GitHub API confirms that Ghostty main is [`5252b193cfd52b4bcd868135e21e4563f2f326ec`](https://github.com/ghostty-org/ghostty/tree/5252b193cfd52b4bcd868135e21e4563f2f326ec), committed at 2026-09-13 03:49:39 UTC. Everything below refers to that commit; the website's material about the first release and the 2025 roadmap is no substitute for the current state of the API.

| Layer | Capabilities and limits |
|---|---|
| The standalone Ghostty application | A Swift / AppKit / SwiftUI shell with Metal rendering on macOS, supporting modern terminal protocols, font handling and native application features. [Official introduction](https://ghostty.org/docs/about), [project description](https://github.com/ghostty-org/ghostty#native-platform-experiences) |
| `libghostty-vt` | The C / Zig interface is already usable and covers terminal parsing / state, input encoding, scrollback and reflow, and the state a custom renderer needs. The current header still states explicitly that the API is unstable and expected to change. [VT header](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/include/ghostty/vt.h) |
| A complete embedding interface | `include/ghostty.h` accepts a macOS `NSView` and offers surface creation, input / IME, the clipboard, drawing and lifecycle callbacks; but it is currently named `libghostty-internal` outright, tailored to Ghostty's own macOS application and not designed as a general external interface. [Internal interface](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/include/ghostty.h) |

The official [Ghostling](https://github.com/ghostty-org/ghostling#what-is-libghostty) explains that the VT library contains no drawing / windowing code, and that the example uses Raylib for that itself. A [Swift XCFramework example](https://github.com/ghostty-org/ghostty/tree/5252b193cfd52b4bcd868135e21e4563f2f326ec/example/swift-vt-xcframework) exists, but it only shows creating a VT, writing control sequences and turning them into plain text, so it cannot be taken as a ready-made complete Metal terminal view.

Ghostty's own [SurfaceView_AppKit.swift](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift) implements input events, `NSTextInputClient`, marked text and the surface calls. From this we infer that if Tursora went through the complete internal interface it would still have to maintain host focus, input methods, keyboard shortcuts, the clipboard, view sizing and lifecycle adaptation, and take on a pinned Zig / library build; this is not a matter of changing a single SPM dependency.

## Relation to the current implementation

Tursora currently uses SwiftTerm's AppKit `LocalProcessTerminalView` with a real PTY, on the default CoreGraphics path. The pinned 1.15.0 does also offer an experimental Metal path, which its source marks as still evolving; this project has not enabled it. [Pinned SwiftTerm source](https://github.com/migueldeicaza/SwiftTerm/blob/dd2fb8ac5b861e7bf617c872895e338f38165648/Sources/SwiftTerm/Mac/MacTerminalView.swift)

Ghostty's GPU and protocol core are worth comparing for heavy output / complex TUIs, but this round produced no evidence that they are faster or lighter in Tursora's real tasks. The bottom-right status, hiding without losing the session, the close confirmation, file browsing and window restoration are all application integration work, and none of it comes for free from replacing the parsing / rendering backend.

Ghostty itself is [MIT licensed](https://github.com/ghostty-org/ghostty/blob/5252b193cfd52b4bcd868135e21e4563f2f326ec/LICENSE), which is compatible with the project's free and open source direction; embedding and distributing it requires keeping its license and the declarations of the dependencies it brings in. The signature of the standalone Ghostty application confers no Developer ID or notarization status on Tursora.

## Recommended next steps

Pin an upstream commit and build an isolated prototype, comparing Chinese input / composed text, fonts and Unicode, Neovim / agent TUIs, scrolling and redraw, copy and paste, CPU / memory, and the shell lifecycle. Use the same optimized build, fonts, window size and input load, with the current SwiftTerm's default and experimental Metal paths as the control. Decide whether to switch only once the benefit and the maintenance cost have been confirmed, and write no performance claims before those results exist.
