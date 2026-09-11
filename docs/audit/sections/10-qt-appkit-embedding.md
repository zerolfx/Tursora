## Qt ↔ AppKit Embedding & Event-Loop Integration

**Scope note on evidence.** Qt is *not installed on this machine* (`brew info qt` → "Not installed"; `/opt/homebrew/opt/qt` is a dangling alias; `brew list --formula` contains neither `qt` nor `extra-cmake-modules`). All Qt-internal citations below were read from the **`qt/qtbase` `dev` branch** via `raw.githubusercontent.com`, which is the 6.11-era tree but *not* the exact 6.11.1 bottle tag; line numbers are marked `≈` and should be re-confirmed once Qt is installed. Dolphin/KIO citations are exact and local. macOS SDK citations are from `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (`xcrun --show-sdk-version` → **26.5**).

---

### 0. Answer up front

**Yes, you can host Qt widgets inside a native `NSWindow`/`NSToolbar` shell, and Qt explicitly supports it — but the recommended shape is the opposite of the naive one.**

| Question | Recommendation |
|---|---|
| Event loop | **Model (a′): Qt owns `QApplication::exec()`**, AppKit objects created normally on the main thread. This *is* the CFRunLoop/AppKit loop — Qt calls `[NSApp run]`. Model (b) is actively harmful. Model (c) (AppKit owns `[NSApp run]`, Qt never calls `exec()`) is supported by Qt but buys nothing and costs the fast path. |
| View embedding | **Qt-in-AppKit, via `QWindow::fromWinId(hostNSView)` + `widget->windowHandle()->setParent(hostQWindow)`** — *not* raw `[hostView addSubview:(NSView*)widget->winId()]`. Reverse direction (AppKit-in-Qt) is easier per-widget but cannot give you `NSSplitViewController`/`NSToolbar` chrome, so it is only a fallback for leaf controls. |
| Menus | **Do not hand-build the `NSMenu`.** Qt already synthesises a real `NSMenu` from Dolphin's `KXmlGui` `QMenuBar`. Hand-building it means fighting `NSApp.mainMenu = newMainMenu;` on every window activation. |
| Biggest single risk | **A split responder chain.** Qt's `NSMenuItem`s use `target = nil` + `@selector(qt_itemFired:)` resolved through `-supplementalTargetForAction:`, so they *grey out* whenever a non-Qt view (your `NSOutlineView` sidebar) is first responder — and your native menu items grey out whenever the Qt view is first responder. This needs a Chromium-style command dispatcher and is the item that decides Phase 2. |

---

### 1. Event loop

#### 1.1 What `QCocoaEventDispatcher` actually is

It is **already CFRunLoop-based**. The constructor installs two `CFRunLoopSourceRef`s and one `CFRunLoopObserverRef` on the main run loop in `kCFRunLoopCommonModes` (`qtbase`, `src/plugins/platforms/cocoa/qcocoaeventdispatcher.mm` ≈440–470):

```objc
context.perform = QCocoaEventDispatcherPrivate::activateTimersSourceCallback;
d->activateTimersSourceRef = CFRunLoopSourceCreate(...);
CFRunLoopAddSource(mainRunLoop(), d->activateTimersSourceRef, kCFRunLoopCommonModes);

context.perform = QCocoaEventDispatcherPrivate::postedEventsSourceCallback;
d->postedEventsSource = CFRunLoopSourceCreate(...);
CFRunLoopAddSource(mainRunLoop(), d->postedEventsSource, kCFRunLoopCommonModes);

d->waitingObserver = CFRunLoopObserverCreate(... kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting ...);
CFRunLoopAddObserver(mainRunLoop(), d->waitingObserver, kCFRunLoopCommonModes);
```

`wakeUp()` is `CFRunLoopSourceSignal(d->postedEventsSource); CFRunLoopWakeUp(mainRunLoop());` (≈370). **Qt timers and `QCoreApplication::postEvent` are delivered by the CFRunLoop, not by a Qt-private loop.** This single fact removes most of the perceived risk.

And when `QApplication::exec()` runs, Qt does not run its own loop — it runs AppKit's (`qcocoaeventdispatcher.mm` ≈270–296):

```objc
if (canExec_Qt && canExec_3rdParty) {
    // We can use exec-mode, meaning that we can stay in a tight loop until
    // interrupted. This is mostly an optimization, but it allow us to use
    // [NSApp run], which is the normal code path for cocoa applications.
    ...
    d->nsAppRunCalledByQt = true;
    [NSApp run];
}
```

Qt also has an explicit, documented "someone else owns NSApp" mode (`qcocoaeventdispatcher.mm` ≈257–265):

```objc
// If Qt is used as a plugin, or as an extension in a native cocoa
// application, we should not run or stop NSApplication; This will be
// done from the application itself. And if processEvents is called
// manually (rather than from a QEventLoop), we cannot enter a tight
// loop and block this call, but instead we need to return after one flush.
const bool canExec_3rdParty = d->nsAppRunCalledByQt || ![NSApp isRunning];
const bool canExec_Qt = (!excludeUserEvents
                         && ((d->processEventsFlags & QEventLoop::DialogExec)
                             || (d->processEventsFlags & QEventLoop::EventLoopExec)));
```

#### 1.2 The three models

| | Model (a) Qt owns loop (`QApplication::exec()`) | Model (b) AppKit owns loop, Qt pumped by timer/observer calling `processEvents()` | Model (c) AppKit owns `[NSApp run]`, Qt never calls `exec()` |
|---|---|---|---|
| Who calls `[NSApp run]` | **Qt does** (≈294). `nsAppRunCalledByQt = true` | `NSApplicationMain` | `NSApplicationMain` |
| Qt timers / posted events | Native, via CFRunLoop sources | **Broken/degraded** — see below | Work: `postedEventsSourceCallback` runs, because its guard is `if (d->processEventsCalled && (flags & EventLoopExec)==0)` and `processEventsCalled == 0` when you never call `processEvents` (≈595–609) |
| Nested `QEventLoop` (`QDialog::exec`, `KJob::exec`) | Fast path: `[NSApp run]` / `[NSApp runModalSession:]` | Re-entrant `processEvents` inside a `processEvents` — undefined-ish | Slow path only: `canExec_3rdParty == false` → manual `nextEventMatchingMask` + `qt_mac_waitForMoreEvents`. Works, but is the least-tested Qt path |
| AppKit sheets / modal sessions | Qt-aware (`beginModalSession`/`cleanupModalSessions`, ≈500–560) | Fights Qt's modal-session stack | AppKit-owned; Qt's modal stack never engages |
| Latency / CPU | Blocks in AppKit properly | Polling — burns CPU or adds latency | Blocks in AppKit properly |
| Effort | ~0 | High | Medium |

**Model (b) is a trap, and the code says so.** `postedEventsSourceCallback` deliberately disables itself while a *manual* `processEvents()` is in flight (`qcocoaeventdispatcher.mm` ≈602–606):

```objc
if (d->processEventsCalled && (d->processEventsFlags & QEventLoop::EventLoopExec) == 0) {
    // processEvents() was called "manually," ignore this source for now
    d->maybeCancelWaitForMoreEvents();
    return;
}
```

A timer-driven `QEventLoop::processEvents()` never sets `EventLoopExec`, so you permanently take the "ignore this source" branch and end up depending on your own poll rate for *all* Qt posted events — including every KIO signal delivery. Do not do this.

**Recommendation: Model (a′).** `main.mm` creates `QApplication` first, creates AppKit objects (`NSWindow`, `NSToolbar`, `NSSplitViewController`) normally afterwards on the main thread, and ends with `return app.exec();`. Because `exec()` bottoms out in `[NSApp run]`, every AppKit facility — sheets, `NSToolbar` customisation, `NSMenu` tracking, `NSSavePanel`, `QLPreviewPanel` — behaves exactly as in a pure-AppKit app. Model (c) is the fallback if a specific AppKit component turns out to need `NSApplicationMain`'s nib loading (it does not; you can load the main nib manually or build everything in code).

#### 1.3 Hazards, and what to do about each

| Hazard | Evidence | Mitigation |
|---|---|---|
| **`NSApp` delegate ownership.** Qt installs `QCocoaApplicationDelegate` and *reflects* to whatever delegate already exists. | `qcocoaintegration.mm` ≈135–140: `if (!testAttribute(Qt::AA_PluginApplication)) { QCocoaApplicationDelegate *newDelegate = [QCocoaApplicationDelegate sharedDelegate]; [newDelegate setReflectionDelegate:[cocoaApplication delegate]]; [cocoaApplication setDelegate:newDelegate]; }` | **Install your `AppDelegate` on `NSApp` *before* constructing `QApplication`.** Qt will then wrap it. `-respondsToSelector:`, `-methodSignatureForSelector:` and `-forwardInvocation:` chain to it (`qcocoaapplicationdelegate.mm` ≈263–281). |
| **`applicationDidFinishLaunching:` ownership.** | `qcocoaapplicationdelegate.mm` ≈152: `if ([reflectionDelegate respondsToSelector:_cmd]) [reflectionDelegate applicationDidFinishLaunching:aNotification];` then `inLaunch = false; ... QCocoaMenuBar::insertWindowMenu();` | Safe — yours runs **first**. But it runs *after* `QApplication` construction, so do not put Qt-independent init there; put it in `main.mm`. |
| **Selectors Qt implements are *not* plain-forwarded.** `applicationShouldTerminate:` returns the reflection delegate's answer and never runs Qt's session-management path (`qcocoaapplicationdelegate.mm` ≈77). | same file | If you implement `applicationShouldTerminate:`, you own Qt shutdown: call `QCoreApplication::quit()` and return `NSTerminateCancel`, mirroring Qt's own behaviour (≈128). |
| **Menu bar ownership.** Qt does `NSApp.mainMenu = nil; NSApp.mainMenu = newMainMenu;` on every menubar update (`qcocoamenubar.mm`, `updateMenuBarImmediately()`). | ibid. | Let Qt own `NSApp.mainMenu` (see §3). If you must own it, you have to suppress every `QMenuBar` in the process. |
| **`NSApplicationActivationPolicy`.** Qt calls `qt_mac_transformProccessToForegroundApplication()` unless `QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM` is set (`qcocoaintegration.mm` ≈129–133). | ibid. | Harmless once you ship a real `.app` bundle with `Info.plist`; only matters for unbundled test binaries. |
| **Autorelease pools.** Qt scopes `QMacAutoReleasePool pool;` around its `processEvents` body (≈237) and around modal-session work (≈502, ≈513). | ibid. | Any of *your* `.mm` code invoked from a Qt slot/timer must wrap long loops in `@autoreleasepool { }`; do not rely on Qt's pool granularity. |
| **Modal sessions / sheets.** Qt maintains `cocoaModalSessionStack`, `beginModalSession()` (≈530) calls `q->interrupt()`, `cleanupModalSessions()` (≈518) calls `[NSApp endModalSession:]`. | ibid. | Prefer **sheets** (`beginSheet:completionHandler:`) over `[NSApp runModalForWindow:]` for your native dialogs; sheets do not enter Qt's modal stack. Never interleave a hand-rolled `NSModalSession` with a `QDialog::exec()`. |
| **Secondary `QEventLoop`s in KIO.** KIO's widgets layer is full of them. | `kio`: `src/widgets/paste.cpp:48` `if (job->exec()) {`, `:50` `dlg.exec()`; `src/widgets/kpropertiesdialog.cpp:194,219,275,292,314,325`; `src/widgets/kpropertiesdialogbuiltin_p.cpp:922,941,962,980,1648,2635,2692,2791,2915,2963`; `src/gui/kprocessrunner.cpp:354` `QEventLoop loop;`; `src/gui/dbusactivationrunner.cpp:105,113`; `src/kioworkers/trash/trashimpl.cpp:357–359` `eventLoop.exec(QEventLoop::ExcludeUserInputEvents)` | Under **model (a′)** these take Qt's supported `[NSApp run]`/`runModalSession:` path and are fine. Under model (c) they take the rarely-exercised manual path. This is a concrete argument for (a′). Note `KIO::WidgetsAskUserActionHandler` is already fully async (`src/widgets/widgetsaskuseractionhandler.cpp:168,186,385` use `setWindowModality(Qt::WindowModal)` + `connect(dlg, &QDialog::finished, ...)`, **no** `exec()`), so the modern KIO UI path does not nest loops. |

---

### 2. View embedding

#### 2.1 `winId()` on macOS

```cpp
WId QCocoaWindow::winId() const
{
    return WId(m_view);
}
```
(`qtbase`, `src/plugins/platforms/cocoa/qcocoawindow.mm` ≈2482–2485) — an **`NSView*`**, never an `NSWindow*`.

#### 2.2 Two directions, and why one is not "just `addSubview:`"

**Direction A — Qt widget hosted in AppKit (recommended).** The Qt 6 supported idiom is *not* to grab `winId()` and `addSubview:` it; it is to wrap the **host** `NSView` in a `QWindow` and reparent onto it:

```objc
// hostView is your NSSplitViewController pane's view
QWindow *hostQWindow = QWindow::fromWinId(reinterpret_cast<WId>(hostView));
container->winId();                              // force native backing
container->windowHandle()->setParent(hostQWindow);
container->windowHandle()->setGeometry(QRect(0, 0, w, h));
container->show();
```

This works because `QCocoaIntegration` implements foreign windows:

```cpp
QPlatformWindow *QCocoaIntegration::createForeignWindow(QWindow *window, WId nativeHandle) const
{ return new QCocoaWindow(window, nativeHandle); }         // ≈283–285
case ForeignWindows: return true;                           // hasCapability, ≈219–220
```
and `QCocoaWindow(QWindow*, WId)` simply `[m_view retain]`s the handle (≈287–295). `recreateWindowIfNeeded()` then takes the *subview* branch instead of creating an `NSWindow` (≈2597–2621):

```cpp
const bool shouldManageTopLevelWindow = !parentWindow && !isSubWindow(window()) && !isForeignWindow();
if (shouldManageTopLevelWindow) { /* new NSWindow */ }
else if (parentWindow) { [parentWindow->view() addSubview:m_view]; }
```

The reason to prefer this over raw `addSubview:` is that Qt's geometry/DPR/activation bookkeeping is driven from `viewDidMoveToSuperview` (≈1678–1715) and `viewDidChangeFrame` (≈1634–1643, handling `NSViewFrameDidChangeNotification` → `handleGeometryChange()`); a raw `addSubview:` of `winId()` leaves `QCocoaWindow` believing it is still a top-level and its `isEmbedded()` state (≈1557–1571) inconsistent.

**Direction B — `NSView` hosted in Qt.** `QWindow::fromWinId(nsView)` + `QWidget::createWindowContainer(qwindow, parent)`. Documented limitations (`qtbase`, `src/widgets/kernel/qwindowcontainer.cpp`): *"The embedded window will stack on top of the widget hierarchy as an opaque box"*; no interop with `QGraphicsProxyWidget`/`QWidget::render()`; focus is delegated only via `QWindow::requestActivate()`; *"Using many window container instances in a QWidget-based application can greatly hurt the overall performance."*

#### 2.3 Mechanics table (Direction A)

| Concern | Rule |
|---|---|
| **Retain/ownership** | `QCocoaWindow` `retain`s the foreign `NSView` you pass to `fromWinId` and releases it on destruction. The `QWindow*` returned by `fromWinId` is **yours** to `delete` — delete it *before* the host `NSView` dies, or Qt will `release` a dead view. Keep the `QWindow*` in the `MainWindowController`'s PIMPL and destroy it in `-dealloc`/`viewDidUnload`. |
| **Resizing** | Do **not** rely on `setAutoresizingMask`. Qt only sets an autoresizing mask defensively when parenting into a *non-flipped* superview to keep y stable (`qcocoawindow.mm` ≈1696–1711). Drive it explicitly: in the host `NSView` subclass override `-setFrameSize:` (or `-viewDidEndLiveResize` for cheap mode) and call `qwindow->setGeometry(QRect(0,0,newSize.width,newSize.height))`. Qt's internal layout then runs normally — `DolphinViewContainer` is a plain `QWidget` with a `QGridLayout`. |
| **HiDPI** | `QCocoaWindow::devicePixelRatio()` (≈2213–2220) derives DPR from `convertToBacking`, i.e. from the hosting `NSWindow`'s `backingScaleFactor`. Since the Qt view is a real subview of your `NSWindow`, this is automatic. Do **not** set `QT_SCALE_FACTOR`/`AA_EnableHighDpiScaling` manually. Watch for `NSWindowDidChangeBackingPropertiesNotification` when a window is dragged between displays — Qt handles it for its own windows; verify for foreign-parented ones (open question). |
| **Layer backing** | `QNSView` does not call `setWantsLayer:` in `initWithCocoaWindow:` (`qnsview.mm` ≈80–106); macOS makes the whole hierarchy layer-backed anyway once *any* ancestor wants a layer, which `NSToolbar`/`NSSplitViewController` guarantee. Set `hostView.wantsLayer = YES` explicitly so the mode is deterministic rather than inherited. |
| **First responder** | `QNSView` returns `YES` from `-acceptsFirstResponder` unless the window refuses key (`qnsview.mm` ≈259–268) and, in `-becomeFirstResponder` (≈231–257), calls `QWindowSystemInterface::handleFocusWindowChanged<SynchronousDelivery>([self topLevelWindow], Qt::ActiveWindowFocusReason)` — so Qt's `focusWindow` *is* updated when hosted in a foreign `NSWindow`. Good news: this is what makes `QCocoaMenuBar::findWindowForMenubar()` work in an embedded shell. |
| **Focus ring** | `self.focusRingType = NSFocusRingTypeNone;` (`qnsview.mm` ≈86). The Qt pane will **never** draw a macOS focus ring; Qt draws its own style focus. Expect a visual mismatch against a native sidebar. (UX finding, not a blocker.) |
| **Rendering** | Dolphin's file view is `KItemListContainer : QAbstractScrollArea` (`dolphin/src/kitemviews/kitemlistcontainer.h:30`) whose viewport is a `QGraphicsView` over a `QGraphicsScene` (`kitemlistcontainer.cpp:31,68`). Pure raster, **no `QOpenGLWidget`, no `QQuickWidget`** anywhere under `src/kitemviews/`. So the entire `DolphinViewContainer` subtree collapses into **one** `QNSView`. That is the ideal embedding case. |

#### 2.4 Known Qt 6 regression

`QMacNativeWidget` (the Qt 5 class purpose-built for this) **was removed in Qt 6.0** and replaced by `QWindow::fromWinId`. [QTBUG-91639](https://bugreports.qt.io/browse/QTBUG-91639) tracks a regression in the replacement: **popup menus / context menus are positioned incorrectly** when a `QWidget` is embedded in a native window via `fromWinId`, where Qt 5.15 + `QMacNativeWidget` was correct. I was unable to read the issue body (bugreports.qt.io redirects to a JS-only Jira), so treat the exact status and fixed-version as an **open question** — but plan a Phase-2 spike that specifically opens Dolphin's context menu and the URL-navigator dropdown inside an embedded pane. Related: [QTBUG-51219](https://bugreports.qt.io/browse/QTBUG-51219) (keyboard input not propagating out of an embedded Qt hierarchy), [QTBUG-49977](https://bugreports.qt.io/browse/QTBUG-49977) (improve QWindow embedding on macOS).

#### 2.5 Which direction — and how much of Dolphin to embed

**Recommend Direction A**, and embed at the **`DolphinViewContainer`** granularity. Decisive evidence: `DolphinViewContainer` has **zero references to `DolphinMainWindow`** —

```
$ grep -n "DolphinMainWindow" src/dolphinviewcontainer.{h,cpp}   # (dolphin) → no matches
```

its constructor is `DolphinViewContainer(const QUrl &url, QWidget *parent)` (`dolphin/src/dolphinviewcontainer.h:66`), and its only main-window coupling is an *injected* `KActionCollection*` parameter on one method (`dolphin/src/dolphinviewcontainer.cpp:401`). It is genuinely a free-standing `QWidget`. `DolphinTabPage`/`DolphinTabWidget` (`QSplitter`/`QTabWidget`, `dolphin/src/dolphintabpage.h:253`, `dolphintabwidget.h:21`) are exactly the pieces you want to *replace* with `NSSplitViewController` + native tabs, so embedding below them is the right seam.

Direction B stays in the toolbox for one case: if `QLPreviewView` or an `NSPathControl` turns out to be wanted *inside* a Qt-laid-out area, wrap it with `createWindowContainer` — accepting the "opaque box on top" stacking caveat.

---

### 3. Focus, keyboard and menus across the boundary

#### 3.1 The AppKit dispatch order

Per Apple's *Handling Key Events*: `NSApplication` recognises a key equivalent from its modifier flags in `-sendEvent:` and sends `-performKeyEquivalent:` to **the key `NSWindow` first**, which walks its view hierarchy depth-first; only if nothing returns `YES` does it try **the main menu**. Windows get first crack; the menu is second.

#### 3.2 Qt deliberately declines

```objc
- (bool)performKeyEquivalent:(NSEvent *)nsevent
{
    if (nsevent.type == NSEventTypeKeyDown && m_composingText.isEmpty()) {
        const bool ctrlDown = [nsevent modifierFlags] & NSEventModifierFlagControl;
        const bool isTabKey = nsevent.keyCode == kVK_Tab;
        if (ctrlDown && isTabKey && sendAsShortcut(KeyEvent(nsevent), [self topLevelWindow]))
            return YES;
    }
    return NO;
}
```
(`qtbase`, `src/plugins/platforms/cocoa/qnsview_keys.mm` ≈48–57)

**`QNSView` returns `NO` for every key equivalent except Ctrl-Tab.** So when a Qt view is first responder, ⌘-shortcuts fall through to `NSApp.mainMenu` — which is precisely what you want in a native shell. Qt shortcuts are instead resolved later, inside `-keyDown:` → `-handleKeyEvent:` → `sendAsShortcut()` (≈59–157). Consequence: **a menu item's key equivalent always beats a Qt `QAction` shortcut with the same key.** That is the correct macOS behaviour and requires no work — but it does mean a `QAction` shortcut that is *not* in the menu bar will still work, and a duplicate will silently be shadowed.

#### 3.3 The real problem: `target = nil` + `supplementalTargetForAction:`

Qt's own menu items are dispatched through the responder chain, not to a fixed target (`qtbase`, `src/plugins/platforms/cocoa/qcocoamenuitem.mm` ≈284–310):

```objc
// Use the responder chain and ensure native modal dialogs continue
// receiving cut/copy/paste/etc. key equivalents.
roleAction = @selector(qt_itemFired:);   // ≈304
m_native.target = nil;                    // ≈309
```

and the object that answers `qt_itemFired:` is a helper hung off `QNSView` (`qnsview.mm` ≈103: `self.menuHelper = [[[QNSViewMenuHelper alloc] initWithView:self] autorelease];`), reached via AppKit's action-resolution hook (`qnsview_menus.mm` ≈12–21):

> *"Qt does not (yet) have a mechanism for propagating generic actions, so we can only support actions that originate from a `QCocoaNSMenuItem`… Instead, we hook in early in the process of determining the target via the `supplementalTargetForAction` API, and if we can support the action we forward it to a helper."*

`-validateMenuItem:` lives in the same helper (≈96–127).

**Therefore, in a mixed shell:**

| First responder | Qt-originated menu items | Native (`AppDelegate`/`MainWindowController`) menu items |
|---|---|---|
| Qt `QNSView` | ✅ enabled, fire correctly | ❌ **greyed out** unless a Qt-side responder implements/validates them |
| Native `NSOutlineView` (Places sidebar) | ❌ **greyed out** — no `QNSView` in the chain to supply `supplementalTargetForAction:` | ✅ enabled |

This is the **single riskiest item in Phase 2**, and it is exactly the problem Chromium solved with a custom dispatcher. Chromium's [command-dispatch-mac](https://www.chromium.org/developers/design-documents/command-dispatch-mac/) document describes the same five-stage order (OS shortcuts → `-performKeyEquivalent:` → menu → remaining OS shortcuts → view actions) and adds two interception points: a `BrowserCrApplication` `NSApplication` subclass and a `ChromeEventProcessingWindow` that overrides `-performKeyEquivalent:` to claim hotkeys *before* the menu.

**Recommended design:**

1. **Let Qt own `NSApp.mainMenu`.** Keep Dolphin's `KXmlGui` menu bar (`dolphin/src/dolphinmainwindow.cpp:214` `setupGUI(Save | Create | ToolBar, ...)`, `dolphinui.rc:5,23,38,68,72,80` → File/Edit/View/Go/Tools/Settings) and let `QCocoaMenuBar` translate it into a real `NSMenu`. You get native menus, native key equivalents (`QAppleKeyMapper::toCocoaKey` / `toCocoaModifiers`, `qcocoamenuitem.mm` ≈244,250) and correct validation for free.
2. **Add a `DolphinCommandDispatcher`** on your `NSWindow` subclass. Override `-performKeyEquivalent:` and, when the current first responder is a *native* pane, translate the event into the corresponding `QAction` (`actionCollection()->action("...")->trigger()`), then return `YES`. When the first responder is the Qt view, return `NO` and let Qt/menu handle it as today.
3. **Bridge validation both ways.** Implement `-supplementalTargetForAction:sender:` on your native pane views, returning a small ObjC shim that owns a `QAction*` map, so `NSMenuValidation` succeeds for Qt-backed commands while the sidebar has focus.
4. **Fix `QNSView`'s absent focus ring** by drawing a 2 px accent-coloured border on the hosting pane view when the Qt window is the focus window (`QGuiApplication::focusWindowChanged`).

#### 3.4 Getting **Space** to reach `QLPreviewPanel`

`QLPreviewPanel` is present in SDK 26.5 (`.../Quartz.framework/Frameworks/QuickLookUI.framework/Headers/QLPreviewPanel.h`) and is **strictly responder-chain driven**: `+sharedPreviewPanel` (line 58), `@property(readonly) id currentController` (line 81), and the informal protocol `-acceptsPreviewPanelControl:` (line 232), `-beginPreviewPanelControl:` (line 239), `-endPreviewPanelControl:` (line 246). It finds its controller by walking the responder chain from the first responder.

The obstacle is that Space currently never leaves Qt. Dolphin intercepts it at `ShortcutOverride` on the main window (`dolphin/src/dolphinmainwindow.cpp:601–612`):

```cpp
bool DolphinMainWindow::event(QEvent *event)
{
    if (event->type() == QEvent::ShortcutOverride) {
        const QKeyEvent *keyEvent = static_cast<QKeyEvent *>(event);
        if (keyEvent->key() == Qt::Key_Space && m_activeViewContainer->view()->handleSpaceAsNormalKey()) {
            event->accept();
            return true;
        }
    }
    return KXmlGuiWindow::event(event);
}
```
with `Qt::Key_Space` also bound as the default shortcut for *toggle selection mode* (`dolphin/src/dolphinmainwindow.cpp:1993`), and `KItemListContainer::keyPressEvent` force-forwarding keys into the `QGraphicsScene` (`dolphin/src/kitemviews/kitemlistcontainer.cpp:130–142`).

**Recipe (three parts, all required):**

1. On macOS, **remove** the `Qt::Key_Space` default shortcut for `toggle_selection_mode` (Cmd-Space is taken by Spotlight anyway; the topbar already advertises `Ctrl+Space`, `dolphin/src/selectionmode/topbar.cpp:48`) — a `#ifdef Q_OS_MACOS` in `setupActions()`.
2. Install a `QObject::eventFilter` on the embedded `DolphinViewContainer` that swallows `Qt::Key_Space` (when not in inline-rename/filter-bar text entry) and calls into the bridge: `DolphinBridge::requestQuickLook(selectedUrls)`.
3. In the bridge (`.mm`), make the **hosting pane `NSView`** (not the `QNSView`) implement the `QLPreviewPanelController` informal protocol, and explicitly make it first responder before `[[QLPreviewPanel sharedPreviewPanel] makeKeyAndOrderFront:nil]`. Do **not** try to make `QNSView` implement it — you cannot add methods to Qt's view class safely, and `-becomeFirstResponder` (≈231–257) will fight you.

This is the cleanest place to prove the whole bridge works end-to-end: it exercises Qt→ObjC calls, selection marshalling (`KFileItemList` → `NSArray<QLPreviewItem>`), and responder-chain manipulation in one feature.

#### 3.5 A UX landmine already in the code

Dolphin **hides its menu bar by default on first run** and routes everything through the `KHamburgerMenu` (`dolphin/src/dolphinmainwindow.cpp:224` `menuBar()->setVisible(false);`, `:243` `hamburgerMenu->setMenuBar(menuBar());`, `:1327`). On macOS the "menu bar" is the *system* menu bar; hiding it yields an app with an almost-empty menu bar and a Windows-style hamburger button in the toolbar. **You must force `showMenuBarAction` on and suppress the hamburger on macOS.**

---

### 4. Threading rules

Both Qt and AppKit require GUI on the main thread. The question is whether KIO breaks that. **It does not** — but it is *not* single-threaded either.

| KIO threading site | What runs off-main | Touches UI? | Evidence (repo `kio`) |
|---|---|---|---|
| **In-process worker threads** — `WorkerThread : QThread` runs a KIO worker's `dispatchLoop()` on its own thread | The whole worker protocol implementation | **No.** Communication is via `ThreadConnectionBackend`, whose affinity is explicitly moved to the worker thread so signals land on the right side: `m_workerBackend->moveToThread(this);` | `src/core/workerthread.cpp:28,50–63`; created at `src/core/worker.cpp:431–433,485–487` |
| Worker-thread teardown | join/reap | No — but **is event-loop-sensitive**: `const bool eventLoopRunning = QThread::currentThread()->loopLevel() > 0;` chooses queued `deleteLater()` vs a blocking `wait()` | `src/core/worker.cpp:210–232` |
| `DeleteJob`'s IO worker | recursive `listDir`/`del` | No | `src/core/deletejob.cpp:193–197` |
| `HostInfo` DNS | `NameLookUpThread : QThread` | No | `src/core/hostinfo.cpp:143` |
| `KUrlCompletion` | `CompletionThread : QThread`, results delivered via `completionThreadDone` signal | No — results are `QStringList`, merged on main thread | `src/widgets/kurlcompletion.cpp:197–226,780,1085,1310` |
| Thumbnail cache I/O | `QtConcurrent::run(loadThumbnailFromCache, ...)` / `saveThumbnailToCache` | **No.** Uses `QImage` (thread-safe, unlike `QPixmap`); the continuation runs on the main thread through `QFutureWatcher<QImage>::finished` | `src/gui/filepreviewjob.cpp:339–348,705,711–719` |
| Checksums in Properties dialog | `QtConcurrent::run(&KChecksumsPlugin::computeChecksum, ...)` | No | `src/widgets/kpropertiesdialogbuiltin_p.cpp:2319,2527` |
| Out-of-process workers | separate `kioworker` processes over `QLocalSocket` | No | `src/core/socketconnectionbackend.cpp:17,91,97` |
| Per-thread caches | `QThreadStorage<KCoreDirListerCache>`, `QThreadStorage<SchedulerPrivate*>` | No — but means **`KCoreDirLister` state is thread-local**; never touch a `KDirLister` from two threads | `src/core/kcoredirlister.cpp:43`; `src/core/scheduler.cpp:96` |

**Also verified: neither repo calls `QCoreApplication::processEvents()` anywhere in non-test code** (`grep -rn processEvents --include="*.cpp"` over `dolphin/src` and `kio/src` → no matches). That eliminates a whole class of re-entrancy surprises.

**Rules for the bridge:**

1. All `KJob`/`KIO` *signals* (`result`, `entries`, `percent`, …) are emitted on the **main thread** — either directly (out-of-process workers, `QLocalSocket` readyRead) or via queued connections from a worker thread. Calling AppKit from a KIO/Qt callback is therefore **safe with no dispatch hop**. Assert it in debug: `Q_ASSERT(QThread::currentThread() == qApp->thread()); NSCAssert(NSThread.isMainThread, ...);`
2. Never call `KIO`/`KFileItem`/`KCoreDirLister` from a `dispatch_async(dispatch_get_global_queue(...))` block. If you must do background work in the AppKit layer, hop back with `dispatch_async(dispatch_get_main_queue(), ...)` — which lands on the same CFRunLoop Qt's dispatcher uses, so it interleaves correctly with Qt posted events.
3. Do **not** call `QCoreApplication::quit()` from inside a `dispatch_after`/`NSTimer` while a KIO worker thread is mid-operation: `Worker::deref()` has two teardown paths keyed on `loopLevel() > 0` (`src/core/worker.cpp:210`), and the no-event-loop path joins synchronously. Quit through `NSApp` → `applicationShouldTerminate:` → `QCoreApplication::quit()` so the loop is still running.

---

### 5. Objective-C++ bridging patterns

**Recommended idiom: opaque C++ facade header + `.mm`-only implementation, with `Q_FORWARD_DECLARE_OBJC_CLASS` for ObjC types that must appear in signatures.**

`Q_FORWARD_DECLARE_OBJC_CLASS` is real and is exactly designed for this (`qtbase`, `src/corelib/global/qdarwinhelpers.h`):

```cpp
#  define Q_FORWARD_DECLARE_OBJC_CLASS(classname) @class classname     // when __OBJC__
// else:
#  define Q_FORWARD_DECLARE_OBJC_CLASS(classname) class classname
```
plus `Q_FORWARD_DECLARE_CF_TYPE(type)` / `Q_FORWARD_DECLARE_MUTABLE_CF_TYPE(type)`.

So `DolphinBridge.h` can be included from *pure C++* TUs (`dolphinviewcontainer.cpp`, your own C++ glue) **and** from `.mm`:

```cpp
// DolphinBridge.h  — no Qt headers, no Cocoa headers
#include <QtCore/qglobal.h>
Q_FORWARD_DECLARE_OBJC_CLASS(NSView);
Q_FORWARD_DECLARE_OBJC_CLASS(NSWindow);
class QWidget;
class DolphinBridgePrivate;

class DolphinBridge {
public:
    DolphinBridge();
    ~DolphinBridge();
    void embedViewContainer(QWidget *container, NSView *host);   // legal in both C++ and ObjC++
    void setHostWindow(NSWindow *w);
private:
    DolphinBridgePrivate *d;   // defined only in the .mm
};
```

#### Practical rules and pitfalls

| Pitfall | Reality on this stack | Rule |
|---|---|---|
| `signals` / `slots` macro collision | **Not a Cocoa problem.** I grepped the SDK: no `#define signals` / `#define slots` anywhere under `MacOSX.sdk/usr/include`, `Foundation.framework`, or `AppKit.framework`. The `#undef signals` folklore comes from GLib/X11, not AppKit. | Do **not** blanket-define `QT_NO_KEYWORDS`: neither repo uses it (`grep -rn "QT_NO_KEYWORDS\|no_keywords"` over `dolphin` + `kio` → no matches) and `KIO`/Dolphin public headers use `Q_SLOTS`/`signals:` freely (e.g. `dolphin/src/dolphinplacesmodelsingleton.h:37` `private Q_SLOTS:`). Prefer the `Q_SIGNALS`/`Q_SLOTS`/`Q_EMIT` spellings in *your* code so a future `QT_NO_KEYWORDS` remains possible. |
| Carbon `check()`/`verify()`/`require()` macros | **Already defused in this SDK.** `AssertMacros.h:1313–1319`: if `__ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES` is unset it now `#define`s it to **`0`** ("*In macOS High Sierra and iOS 11, if we haven't set this yet, it now defaults to off*"). | No action needed, but keep `-D__ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES=0` in the CMake target as belt-and-braces if you ever pull in an old `<CoreServices/CoreServices.h>`. |
| ObjC `id` typedef vs C++ identifiers | Low risk. `id` as a *parameter name* is legal C++ even when `id` is a typedef, so `virtual void virtual_hook(int id, void *data);` (`kio/src/core/slavebase.h:925`, `kio/src/core/kacl.h:184`, `kio/src/widgets/fileundomanager.h:108`) compiles in ObjC++. `struct SHM { SHM(int id, uchar *address); }` (`kio/src/gui/filepreviewjob.h:57`) likewise. | No mitigation needed; just don't `#include <objc/objc.h>` before Qt headers gratuitously. |
| **ARC vs MRR** | **Qt itself is built without ARC** — direct proof: `qcocoaapplicationdelegate.mm` ≈263–267 contains `[oldDelegate retain]; [reflectionDelegate release];`, which will not compile under `-fobjc-arc`. | ARC is a **per-TU** flag, so you *can* use ARC in your `.mm` files. But: (a) never let an ARC-managed `NSView*` be the only owner of a view you also hand to `QWindow::fromWinId` (Qt `retain`s it — that is fine, but the release order matters); (b) `__bridge`/`__bridge_retained` casts are required for any `void*` you stash in a C++ PIMPL. **Recommendation: compile the `macos/` target with `-fno-objc-arc`** and use explicit `retain`/`release` + `QMacAutoReleasePool`, matching Qt. It removes an entire class of "who owns the `NSView`" bugs at the Qt boundary and costs about 20 lines of discipline. |
| C++20 | `dolphin/CMakeLists.txt:18` `set(CMAKE_CXX_STANDARD 20)`, `:20` `CMAKE_CXX_STANDARD_REQUIRED TRUE`. Clang's ObjC++ supports `-std=c++20` fine; but note that with `-fobjc-arc`, ObjC pointers are not trivially-copyable, which breaks `std::bit_cast`/`memcpy`-style tricks and some `constexpr` contexts. | Another reason for `-fno-objc-arc`. Set `set_source_files_properties(*.mm PROPERTIES COMPILE_OPTIONS "-fno-objc-arc;-fobjc-weak")`. |
| Mixed TU discipline | Objective-C++ `.mm` files that `#include <QtWidgets/...>` **and** `#import <AppKit/AppKit.h>` compile, but slowly and with confusing diagnostics. | Keep a **hard rule**: one `.mm` per bridge concern; Qt headers only in the `.mm`'s implementation section, Cocoa headers only above; nothing in shared headers except `Q_FORWARD_DECLARE_OBJC_CLASS` + opaque pointers. |
| Namespaced Qt builds | If KF6 is ever built against a `-qtnamespace`'d Qt, `QT_MANGLE_NAMESPACE` affects ObjC class names Qt registers. Homebrew's `qt` is not namespaced. | Non-issue for the Homebrew build; note it if you later vendor Qt. |

---

### 6. Prior art — honest assessment

| Precedent | What it actually does | Useful to us? |
|---|---|---|
| **KDE Craft macOS bundles** (Dolphin/digiKam/Kdenlive on macOS today) | Ship the **pure Qt UI** in a `.app` bundle. Craft is a build/packaging framework; the KDE wiki's macOS page recommends it as the way to *build*, not as a native-shell strategy. No AppKit shell, no `NSToolbar`, no `NSSplitViewController`. | **Only for build/packaging.** Zero prior art for the embedding question. |
| **digiKam / Kdenlive** | Qt widgets end-to-end on macOS. | Proves KF6-on-macOS is viable at the *framework* level; says nothing about AppKit embedding. |
| **Chromium on macOS** | Native `NSMenu` + `NSWindow` over a non-AppKit content view; solves the exact responder-chain/key-equivalent problem with `BrowserCrApplication` (`NSApplication` subclass) and `ChromeEventProcessingWindow` overriding `-performKeyEquivalent:`. | **The single most relevant prior art**, and it is publicly documented. Copy the dispatcher architecture (§3.3). |
| **Qt's own `QMacNativeWidget`** (Qt ≤5.15) | Purpose-built class for putting a Qt hierarchy in a non-Qt `NSView`/`NSWindow`. **Removed in Qt 6.0**, replaced by `QWindow::fromWinId`. | The *pattern* is blessed; the *convenience class* is gone, and the replacement has at least one open regression ([QTBUG-91639](https://bugreports.qt.io/browse/QTBUG-91639)). |
| Qt's `Qt::AA_PluginApplication` | Suppresses delegate installation and Apple-event handler removal (`qcocoaintegration.mm` ≈135, ≈169). Notably, `qcocoamenubar.mm` does **not** test it, so the menu-bar sync still runs. | Available if you go model (c). **Not recommended** for us — we *want* Qt's menu-bar sync and Qt's delegate reflection. |
| "kdeconnect-ios" | I could not find any evidence this is relevant; kdeconnect's iOS client is a separate Swift app, not a Qt-embedding effort. | **Open question / probably irrelevant.** Do not cite it. |

---

### 7. Concrete Phase-2 skeleton

#### 7.1 Target layout

```
macos/
├── CMakeLists.txt                 # add_executable(dolphin-macos MACOSX_BUNDLE ...)
│                                  # target_compile_options(... -fno-objc-arc -fobjc-weak)
│                                  # target_link_libraries(dolphin-macos PRIVATE
│                                  #     dolphinprivate KF6::KIOWidgets KF6::XmlGui
│                                  #     "-framework AppKit" "-framework Quartz"
│                                  #     "-framework QuartzCore" "-framework UniformTypeIdentifiers")
├── Info.plist.in                  # LSMinimumSystemVersion 26.0, NSHighResolutionCapable,
│                                  # CFBundleDocumentTypes (public.folder), NSSupportsAutomaticTermination NO
├── main.mm                        # QApplication + NSApp bootstrap, ends in app.exec()
├── AppDelegate.h/.mm              # NSApplicationDelegate; installed BEFORE QApplication
├── MainWindowController.h/.mm     # NSWindowController + NSToolbarDelegate
│                                  #   + NSSplitViewController (sidebar | content)
├── QtHostView.h/.mm               # NSView subclass: owns the QWindow* from fromWinId,
│                                  #   overrides -setFrameSize: -> qwindow->setGeometry()
├── DolphinBridge.h/.mm            # opaque C++ facade; the ONLY file including both worlds
├── CommandDispatcher.h/.mm        # performKeyEquivalent: + supplementalTargetForAction: bridge
├── PlacesDataSource.h/.mm         # NSOutlineView data source over DolphinPlacesModel
├── QuickLookController.h/.mm      # QLPreviewPanelController + QLPreviewItem adapter
└── ToolbarItems.mm                # NSToolbarItem <-> QAction (KActionCollection) mapping
```

The bridge's model source already exists and is a plain `QAbstractItemModel`: `DolphinPlacesModel : KFilePlacesModel` (`dolphin/src/dolphinplacesmodelsingleton.h:22`), reachable as a singleton — so `PlacesDataSource.mm` is a `QAbstractItemModel` → `NSOutlineViewDataSource` shim listening to `rowsInserted`/`dataChanged` and calling `-reloadItem:`.

#### 7.2 Exact startup sequence

```
 1. main(argc, argv)                                   [main.mm, C++ side]
 2. KIconTheme::initTheme();                            // MUST precede QApplication
                                                        // (mirrors dolphin/src/main.cpp:71)
 3. [NSApplication sharedApplication];                  // materialise NSApp
 4. NSApp.delegate = [[AppDelegate alloc] init];        // ← BEFORE step 5, so Qt reflects to it
                                                        //   (qcocoaintegration.mm ≈135-140)
 5. QApplication app(argc, argv);                       // installs QCocoaApplicationDelegate,
                                                        //   sets reflectionDelegate = ours,
                                                        //   installs CFRunLoop sources
 6. KStyleManager::initStyle();  /* or setStyle("breeze") — dolphin/src/main.cpp:80-90 */
 7. KLocalizedString::setApplicationDomain("dolphin");
 8. KAboutData::setApplicationData(aboutData);
 9. QCommandLineParser ... parser.process(app);
    // SKIP: KCrash::initialize(), KDBusService, DBusInterface, MainWindowAdaptor
    //       (dolphin/src/main.cpp:100,183,206-207; dolphinmainwindow.cpp:142
    //        `new MainWindowAdaptor(this);` -- see the D-Bus audit section)
10. auto *controller = [[MainWindowController alloc] init];      // builds NSWindow,
                                                                 //   NSToolbar,
                                                                 //   NSSplitViewController
11. [controller.window makeKeyAndOrderFront:nil];       // window must exist & be on screen
                                                        //   before Qt reparents into it
12. bridge->embedViewContainer(new DolphinViewContainer(url, nullptr),
                               controller.contentPaneView);
    //  inside DolphinBridge.mm:
    //    hostQWindow = QWindow::fromWinId((WId)hostView);      // createForeignWindow ✔
    //    container->winId();                                   // force native backing
    //    container->windowHandle()->setParent(hostQWindow);
    //    container->windowHandle()->setGeometry(hostView.bounds);
    //    container->show();
13. bridge->installMenuBar();     // construct a hidden KXmlGuiWindow-less QMenuBar from
                                  //   Dolphin's KActionCollection so QCocoaMenuBar
                                  //   populates NSApp.mainMenu
14. [CommandDispatcher attachTo:controller.window bridge:bridge];
15. return app.exec();            // -> [NSApp run]  (qcocoaeventdispatcher.mm ≈294)
```

Step 4-before-5 is the load-bearing ordering constraint. Step 11-before-12 matters because `QCocoaWindow::devicePixelRatio()` and `viewDidMoveToSuperview()` need a real `NSWindow` to resolve against.

#### 7.3 Recommended Phase-2 spike order (each ~½–1 day, do them in this order)

1. Empty `NSWindow` + `QApplication::exec()` + a `QPushButton` embedded via `fromWinId` — proves the loop and the embed.
2. Resize the window; verify Qt relayout and DPR on a 1× external display.
3. Embed the real `DolphinViewContainer`; open a context menu — this is the [QTBUG-91639](https://bugreports.qt.io/browse/QTBUG-91639) probe.
4. Add a `QMenuBar` from `KActionCollection`; verify ⌘-shortcuts fire while the Qt view has focus.
5. Add a native `NSOutlineView` sidebar; verify which menu items grey out — this measures the §3.3 dispatcher work.
6. Space → `QLPreviewPanel`.

If steps 1–4 pass cleanly, Phase 2 is a matter of grind, not of research. If step 3 or 5 fails, the fallback is a Qt-owned `QMainWindow` with `NSToolbar`-styled `QToolBar` and `setUnifiedTitleAndToolBarOnMac`-style theming — a real but much less native result.

---

### Sources

- [Handling Key Events — Apple Developer Archive](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingKeyEvents/HandlingKeyEvents.html)
- [Menus, Hotkeys, & Command Dispatch (Mac) — Chromium](https://www.chromium.org/developers/design-documents/command-dispatch-mac/)
- [QTBUG-91639 — QWidget embedded in native window (Qt 5.15→6.x regression)](https://bugreports.qt.io/browse/QTBUG-91639)
- [QTBUG-51219 — Embedding QMacNativeWidget blocks keyboard input to host](https://bugreports.qt.io/browse/QTBUG-51219)
- [QTBUG-49977 — macOS: Improve QWindow embedding support](https://bugreports.qt.io/browse/QTBUG-49977)
- [QMacNativeWidget (Qt 5.15, removed in Qt 6)](https://doc.qt.io/qt-5/qmacnativewidget.html)
- [KDE Community Wiki — Get Involved/development/Mac](https://community.kde.org/Get_Involved/development/Mac)
