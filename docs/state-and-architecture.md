# State, Events & Application Architecture

This guide covers how to structure real-world `swift-rune` applications: configuring `AppSpec` vs `App`, handling events with `Cx` and `Tx`, driving 120 Hz updates with `Live<T>`, coordinating async background work, handling text input and drag-and-drop, supporting accessibility, and integrating desktop OS features.

---

## 1. `AppSpec<State>` vs `App<State>`

### `AppSpec<State>` (Concise Entry Point)

Best for single-window apps, tools, and demos:

```swift
import Rune

let spec = AppSpec<MyState>(
    title: "My Tool",
    size: Vec2(960, 640),
    minSize: Vec2(640, 420),
    state: MyState(),
    setup: { waker in
        startBackgroundWorker(waker: waker)
    },
    poll: { state, elapsed, tx in
        // Drain background channels; return true if state changed
        return drainInbox(into: &state, tx: &tx)
    },
    onKey: { state, keyEvent, tx in
        // Global window key handler; return true if handled
        return handleShortcut(keyEvent, state: &state, tx: &tx)
    },
    onFileDrop: { state, urls, tx in
        state.openFiles(urls)
    },
    view: myView
)
.scene("empty") { $0.items = [] }
.scene("populated") { $0.loadSampleData() }

RuneApp.runOrExit(spec)
```

### `App<State>` (Full Desktop & Browser Control)

Use `App<State>` when you need custom window chrome, menus, multi-window support, floating overlays, global shortcuts, lifecycle hooks, or a custom GPU `Compositor`:

```swift
var app = App<MyState>(
    title: "Studio",
    size: Vec2(1200, 800),
    state: MyState(),
    view: studioView
)
.minSize(800, 520)
.chrome(.borderless)               // or .standard / custom .titlebar(...)
.keepRunning(true)                 // keep process alive on macOS when last window closes
.onFocus { state, focused, _ in
    state.windowIsActive = focused
}
.onClose { state, _ in
    // Return false to veto closing (e.g. show unsaved-changes dialog)
    return !state.hasUnsavedChanges
}
.onOpenUrl { state, url, _ in
    state.handleDeepLink(url)
}

// Obtain a thread-safe AppHandle to drive the app from outside the UI thread
let handle: AppHandle<MyState> = app.handle()

try RuneApp.run(app)
```

### `AppHandle<State>` (External Control & Thread-Safe Updates)

`AppHandle<State>` lets background services, Swift concurrency tasks, or menu callbacks safely mutate state and control the window:

```swift
Task {
    let items = try await apiClient.fetchItems()
    handle.update { state, tx in
        state.items = items
        tx.announce("Loaded \(items.count) items")
    }
}

// Window & app control methods on AppHandle:
handle.wake()
handle.show()
handle.hide()
handle.focus()
handle.minimize()
handle.close()
handle.quit()
handle.setPosition(Vec2(100, 100))
```

---

## 2. View Context (`Cx<State>`)

`Cx<State>` is passed to your view function each frame so you can adapt to the environment and inspect retained layout state:

| Member | Purpose |
| :--- | :--- |
| `cx.viewport` | Current window/canvas size in logical points (`Vec2`) |
| `cx.pixelScale` | Display backing scale factor (e.g. `1.0`, `2.0`, `3.0`) |
| `cx.systemDark` | Current OS dark/light appearance |
| `cx.reducedMotion` | OS "Reduce Motion" preference (override with `cx.reducedMotion(Bool)`) |
| `cx.windowFocused` | Whether the host window currently has OS focus |
| `cx.focusedKey` | Key of the currently focused element, if any |
| `cx.hoveredKey` | Key of the currently hovered element (automatically tracks hover dependency) |
| `cx.pressedKey` | Key of the currently pressed element |
| `cx.isFocused("key")` | Convenience focus check for a key |
| `cx.isHovered("key")` | Convenience hover check for a key |
| `cx.isPressed("key")` | Convenience press check for a key |
| `cx.scrollOffset(of: "key")` | Current `(x, y)` scroll offset of a scroll container |
| `cx.scrollMax(of: "key")` | Maximum scrollable offset of a scroll container |
| `cx.viewportSize(of: "key")` | Visible viewport size of a scroll container |
| `cx.contentSize(of: "key")` | Total content size of a scroll container |
| `cx.layoutRect(of: "key")` | Previous frame's laid-out `MotionRect` for a keyed element |
| `cx.layoutSize(of: "key")` | Previous frame's `(width, height)` for a keyed element |
| `cx.waker` | `Waker` handle to wake the app from async tasks |
| `cx.timeScale(_:)` | Scales animation speed (useful for slow-motion inspection or user settings) |

---

## 3. Transactions (`Tx`)

Callbacks with the `(inout State, inout Tx) -> Void` signature receive a `Tx` transaction that lets you schedule side effects atomically alongside your state mutation:

### Focus & Accessibility
```swift
tx.focus("search-input")                     // move keyboard focus to a keyed element
tx.blur()                                    // clear focus
tx.returnFocus("open-dialog-btn")            // restore focus when closing an overlay
tx.announce("Saved successfully", .polite)   // screen-reader announcement (.polite / .assertive)
```

### Programmatic Scrolling
```swift
tx.scrollTo("feed", x: 0, y: 240)
tx.scrollToInstant("feed", x: 0, y: 0)
tx.scrollToWith("feed", x: 0, y: 400, spring: Tok.Motion.CALM)
tx.scrollIntoView("row-42")
tx.scrollCenter("row-42")
tx.scrollToBottom("chat-log")
tx.scrollToBottomInstant("chat-log")
tx.scrollPage("feed", 1)                     // +1 page down, -1 page up
tx.keepOnScreen("active-item")
```

### Clipboard, Window & Timing
```swift
tx.copyText("Copied string")
tx.requestPaste()
tx.setTitle("Document — Edited")
tx.toggleMaximized()
tx.toggleFullScreen()
try? tx.openURL("https://github.com/mweinbach/swift-rune")
tx.wakeAfter(0.5)                            // schedule a future poll/redraw in 0.5s
tx.quit()
```

### Controlling Motion Per-Transaction
```swift
tx.instant()                                 // skip animations for this state change
tx.settle()                                  // snap running animations to target
tx.motion(Tok.Motion.POP)                    // override spring for this commit
tx.colorMotion(Tok.Motion.CALM)              // override color transition spring
tx.liveOnly()                                // repaint live bindings without full view rebuild
```

---

## 4. High-Frequency Updates (`Live<T>` & `Binding<T>`)

For values that update every frame (audio meters, scrubbers, live telemetry, hover glows, progress indicators), use `Live<T>` so Rune updates the GPU primitives directly **without** rebuilding and re-laying out the view tree:

```swift
struct MeterState {
    let level = Live<Float>(0.0)
    let glowColor = Live<Color>(Tok.accent(0, dark: true))
    let status = Live<String>("Idle")
}

// Bind in your view (runs once when building the tree):
el()
    .key("meter")
    .size(120, 120)
    .rounded(16)
    .bg(t.card)
    .liveScale(state.level.smooth(Tok.Motion.SNAPPY))
    .liveBorder(state.glowColor.smooth(Tok.Motion.DEFAULT))
    .child(liveText(state.status).color(t.text))

// Mutate from anywhere (even a background timer or drag handler):
state.level.set(0.85)                                // smooth spring to 0.85
state.level.snap(1.0)                                // jump immediately
state.level.pulse(active: 1.12, rest: 1.0, holdSeconds: 0.1)
state.status.set("Recording...")
```

Available live modifiers on `El<State>`:
- `.liveOpacity(_:)`
- `.liveScale(_:)`
- `.liveBlur(_:)`
- `.liveBorder(_:)`
- `.liveShadow(_:)`
- `.liveGradient(_:_:)`
- `liveText(_:)`

---

## 5. Async State & Cancellation (`Attempt`, `Seq`, `Waker`)

`Rune` includes lightweight async state-machine primitives (`Sources/Rune/Machine.swift`) for preventing stale-response race conditions:

- **`Attempt<Value, Err>`**: Tracks an async operation's lifecycle (idle, loading, succeeded, failed) with `.map(_:)` and `.mapError(_:)`.
- **`Seq` / `AttemptToken`**: Monotonic sequence generator so when a user types quickly into a search box, earlier in-flight responses are ignored via `seq.isCurrent(token)`.
- **`Waker`**: Thread-safe wakeup signal passed to `.setup { waker in ... }` and `cx.waker`. Call `waker.wake()` from any background thread or `Task` to wake the event loop cleanly (essential on idle desktop windows and single-threaded WebAssembly reactors).

---

## 6. Input & Event Handling

### Pointer, Hover & Drag

```swift
el()
    .key("slider-track")
    .size(220, 24)
    .hover(t.hover)
    .press(t.press)
    .onHover { state, isHovered, _ in
        state.isHoveringTrack = isHovered
    }
    .onClick { state, tx in
        // Primary click (or keyboard Space/Enter when focused)
    }
    .onDrag { state, drag, tx in
        switch drag.phase {
        case .down:
            state.dragStart = state.value
        case .move:
            let ratio = (drag.local.x / max(1, drag.size.x)).clamped(to: 0...1)
            state.value = ratio
        case .up:
            if drag.isCancelled, let start = state.dragStart {
                state.value = start
            }
            state.dragStart = nil
        }
    }
    .onWheel { state, wheel, _ in
        // wheel.dx, wheel.dy, wheel.precise, wheel.mods
        return false // return true to consume event
    }
```

### Keyboard & Shortcuts (`KeyEvent`, `Mods`, `Chord`)

```swift
// Element-level key handler (fires when focused or bubbling from a focused child)
col()
    .key("editor-pane")
    .onKey { state, ev, tx in
        if ev.mods.primaryCommand, case .text("s") = ev.key {
            state.save()
            tx.announce("Saved")
            return true
        }
        if ev.key == .escape {
            state.dismissModal()
            return true
        }
        return false
    }
```

Use `Chord.parse("mod+shift+k")` for cross-platform shortcut matching (`mod` resolves to `Cmd` on Apple platforms and `Ctrl` on Windows/Linux).

### Text Editing (`TextEdit`)

```swift
struct FormState {
    var email = TextEdit()
    var notes = TextEdit("Hello\nWorld")
    var password = TextEdit()
}

// Single-line input
textInput(key: "email", \FormState.email)
    .singleLine()
    .placeholder("you@example.com", color: t.textSecondary)
    .spellcheck(false)
    .onChange { state, newValue, _ in
        state.validateEmail(newValue)
    }
    .onSubmit { state, value, tx in
        tx.focus("notes")
    }
```

`TextEdit` handles grapheme-cluster navigation, word/line selection, undo/redo history, IME preedit clauses, password masking (`isSecure = true`), rich marks, and OS spellchecking.

### File Drop, Outbound Drag & Rich Clipboard

- **Inbound File Drop**: Pass `onFileDrop: { state, urls, tx in ... }` or `onFileDropPhase: { state, phase, tx in ... }` on `AppSpec` / `App` to highlight drop zones and accept dropped files.
- **Outbound Drag**: Attach `.onDragStart` / `.onDragOutEnd` to let users drag text, images, or file URLs out of your Rune window into other desktop apps (see `Sources/Examples/RuneDragOut`).
- **Rich Clipboard**: Handle `.onPasteContent { state, content, tx in ... }` to read plain text, HTML, RTF, images, or file URLs from `ClipboardContent` (see `Sources/Examples/RuneRichClipboard`).

---

## 7. Accessibility Best Practices

Rune automatically projects your tree to native OS accessibility bridges (NSAccessibility, UIAccessibility, Windows UI Automation, Linux AT-SPI, Android AccessibilityNodeProvider, Browser DOM/ARIA):

```swift
el()
    .key("mute-toggle")
    .role(.switchControl)                  // .button, .switchControl, .checkbox, .tab, .listItem, .heading, .progress, .separator, .group...
    .label("Mute microphone")              // accessible name
    .description("Silences audio input")   // accessible description
    .checked(state.muted)                  // or .selected("true" / "false")
    .focusable(true)
    .focusRing(accent)
    .help("Mute microphone  Cmd+Shift+M")  // tooltip + help text
```

- Mark purely decorative children (like a switch's inner knob or icon inside a labelled button) with `.a11yHidden()`.
- Group vertical navigation lists with `.focusGroup(true)` and headings with `.headingLevel(1...6)`.
- When closing a modal dialog or popover, call `tx.returnFocus("trigger-key")` (or set `.focusReturn("trigger-key")`) so keyboard and screen-reader users don't lose their place.

---

## 8. Desktop Services (`RuneNotify`, `RuneMac`, `RuneI18n`)

### System Notifications (`RuneNotify`)

```swift
import RuneNotify

// On Windows, register an app identity once during startup:
let _ = RuneNotify.registerWithResult(.init(id: "com.example.myapp", name: "My App"))
```

`RuneNotify` delivers native notifications through Apple `UserNotifications`, Windows WinRT toasts, and Linux freedesktop D-Bus notifications, supporting replacement, removal, click callbacks, inline replies, and a deterministic test backend.

### Internationalization (`RuneI18n`)

```swift
import RuneI18n

let locale = LocaleInfo.parse("en-US")!
let catalog = try Catalog.fromJSON(jsonData)
let i18n = I18n(locale: locale, catalog: catalog)
```

`RuneI18n` provides BCP-47 locale parsing, RTL detection, script-aware `negotiateLocale`, CLDR `PluralCategory` rules, number/list formatting, and `{{name}}` template interpolation.

### macOS Window Persistence (`RuneMac`)

Add `.product(name: "RuneMac", package: "swift-rune")` for `NSWindow` frame persistence/autosave, multi-display clamping, fullscreen handling, and relaunch helpers on macOS.
