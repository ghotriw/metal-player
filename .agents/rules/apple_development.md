# Modern Apple Development Standards (macOS 15+ / Swift 6)

## 1. Requirement to Verify APIs via Apple Docs
- The `apple-docs` MCP server is available (`search_apple_docs`, `get_apple_doc_content`, `search_framework_symbols`, `get_platform_compatibility`).
- **MANDATORY**: When writing, updating, or reviewing code for AppKit, SwiftUI, AVFoundation, Metal, and CoreMedia, always check modern APIs and avoid obsolete/deprecated patterns.
- Do NOT guess or rely on pre-2023 training memory for Apple APIs.

## 2. Deprecated & Prohibited Patterns
- ❌ **Do NOT use `NSApp.activate(ignoringOtherApps:)`** (Deprecated in macOS 14.0).
  ✅ **Use `NSApp.activate()`**.
- ❌ **Do NOT use `ObservableObject` and `@Published`** from Combine for application state in macOS 14+.
  ✅ **Use the `@Observable` macro** from the `Observation` framework.
- ❌ **Do NOT use imperative `isFocused = true` inside `.onAppear`**.
  ✅ **Use `.defaultFocus(_:_:)`** and configure `window.initialFirstResponder = hostingView` in AppKit `NSWindowController`.
- ❌ **Do NOT allocate new objects/adapters inside SwiftUI computed properties** (e.g. `var actionsAdapter: any PlayerActions { ... }`).
  ✅ Pass dependencies or manage state in `@State` / dedicated controllers.

## 3. Keyboard Shortcuts & Menu Architecture
- **Global Menus (`CommandMenu`)**:
  - Must ONLY use standard system shortcuts with modifier keys (e.g., `⌥→`, `⌥←`, `⌃⌘F`, `⌘I`, `⌘O`).
  - Must NEVER assign unmodified navigation keys (`Space`, `←`, `→`, `↑`, `↓`, `m`) to `CommandMenu` items with `modifiers: []`.
  - Unmodified menu shortcuts intercept key events before the view's responder chain, causing dead/swallowed keys when items are disabled.
- **View-Level Shortcuts**:
  - Single-key/unmodified navigation shortcuts for media players (`Space`, arrows, `m`, `d`, `esc`) belong strictly inside the player view via `.onKeyPress`.
