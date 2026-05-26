# Pangolin macOS Client — Changes vs. upstream `fosrl/apple`

This document summarizes everything that diverges from the original
`https://github.com/fosrl/apple.git` checkout. The deployment target stays
**macOS 14.0 (Sonoma)**; nothing here raises the minimum OS.

## 1. New feature — Resources list in the menu bar

Original menu bar had no way to see/access org resources after connecting.
A complete resource browser was added inside the menu bar.

### New API surface (`Pangolin/Shared/`)
- `Models.swift` — `UserResource`, `UserSiteResource`, `GetUserResourcesData`,
  `SiteResourceDetail` (with `siteIds`, `siteNames`, `siteOnlines`,
  `tcpPortRangeString`, `udpPortRangeString`, `disableIcmp`),
  `ListAllSiteResourcesData`.
- `APIClient.swift` —
  `listUserResources(orgId:)` → `GET /org/{orgId}/user-resources`,
  `listAllSiteResources(orgId:pageSize:)` → `GET /org/{orgId}/site-resources`.

### Long‑lived `ResourceCache` (in `MenuBarView.swift`)
- `@MainActor ObservableObject` with `@Published` resources, loading,
  lastFetched, lastError.
- 3‑minute background polling, only when the tunnel is `.connected`.
- Manual `refresh()` re‑arms the polling timer (no double fetch).
- Token‑based stale‑result guard (`refreshSequence`) — concurrent refreshes
  cannot overwrite each other with stale data.

### Menu UX
- Public / Private submenus with hover‑to‑open behavior.
- Search field with live filtering; auto‑focused on submenu open.
- Site grouping in Private list with online indicators and per‑group counts.
- Sticky pinned section headers with opaque background.
- Resource detail panel (3rd depth) with Open / Copy Alias / Copy Address;
  brief "✓ Copied" / "✓ Opened" feedback row after each action.
- Manual Refresh row with timestamp + spinner.
- "Connect to Pangolin" placeholder when disconnected.

## 2. Menu bar architecture — SwiftUI `MenuBarExtra` → AppKit

Original used `MenuBarExtra(.window)`. The menu bar host has been rewritten
with AppKit primitives for reliable click handling and uniform behavior at
every panel depth.

### `PangolinApp.swift`
- `MainMenuController` — `NSStatusItem` + custom `FocusableMenuPanel`
  (`NSPanel` subclass) + `FirstMouseHostingController`
  (`NSHostingController` subclass with `acceptsFirstMouse = true`).
- Click on the status item toggles the main panel; a global mouse monitor
  + 0.25 s mouse‑out timer dismiss on outside interaction.
- Connected‑state status icon badge: composited orange disc with white
  checkmark in the bottom‑right (cached image, redraws only on the first
  transition).

### `MenuBarView.swift`
- `MenuPanelController` — reusable controller for 2nd‑depth submenus and
  3rd‑depth detail panels (anchored `NSPanel`, key‑window transfer on first
  click via `sendEvent` override).
- `SubmenuCoordinator` — ensures only one `HoverSubmenuRow` is open at a time.
- `HoverSubmenuRow` — hover‑delay scheduling, keep‑open signal for nested
  detail panels.
- `AnchorReader` (`NSViewRepresentable`) — reports row screen frames; overrides
  `setFrameOrigin` / `setFrameSize` so position‑only layout shifts (e.g.
  logout shrinking the menu) update the anchor.
- `CustomSwitch` — replaces SwiftUI's `Toggle(.switch)`, which dims when its
  window isn't key.
- `ConnectToggleRow` — status dot + custom switch.
- Section headers ("ACCOUNT", "ORGANIZATION", "RESOURCES").
- `MenuItemFeedbackRow` — transient action feedback.

## 3. All SwiftUI `WindowGroup`s → AppKit `NSWindow`

Triggered by a hard crash on macOS 26: the Preferences window's
`NavigationSplitView` + `.windowResizability(.contentSize)` produced a layout
cycle that threw `NSException` from `_postWindowNeedsUpdateConstraints`.

### `AppWindowsController` (new singleton)
- Lazily creates and caches `NSWindow` + `NSHostingController` for: Login,
  Onboarding, Preferences.
- All window‑level configuration (styleMask, identifier, title, button
  visibility, content size) is set explicitly at creation — never mutated
  during a layout pass.
- `centerOnScreen(_:)` helper places windows at the horizontal center,
  slightly above the vertical midline of `screen.visibleFrame` (works
  correctly on multi‑display setups).
- `NSWindowDelegate.windowWillClose` updates the dock activation policy.

### `PangolinApp` body reduced to `Settings { EmptyView() }`
SwiftUI's `App` protocol still requires one Scene; the `Settings` scene is
the standard "no main window" idiom for menu‑bar apps.

### Removed
- `OpenWindowBridge` (hidden 1×1 SwiftUI WindowGroup that proxied
  `openWindow`).
- `WindowAccessor` (LoginView), `OnboardingWindowAccessor`,
  `PreferencesWindowAccessor` (file fully deleted).
- `configureWindow(_:)` / `configureOnboardingWindow(_:)` methods that
  synchronously mutated `styleMask` during SwiftUI body evaluation.
- Inline `setActivationPolicy(.regular)` / `.accessory` toggling scattered
  across views (centralized in `AppWindowsController`).
- All direct `@Environment(\.openWindow)` usage in `MenuBarView`.
- Outer `.frame(minWidth: 600, minHeight: 400)` on `PreferencesWindow` (the
  layout‑cycle source).
- `.onReceive(NSWindow.didBecomeKeyNotification)` synchronous `styleMask`
  mutation in `PreferencesWindow` and `LoginView`.

### Notification bridge
The `pangolinOpenWindow` notification is now observed directly by
`PangolinAppDelegate`, dispatched to `AppWindowsController.show(id:)`.
Helper: global `postOpenWindow(id: String)`.

## 4. Onboarding UX

`MenuBarView.mainContent` is now split:
- `onboardingMenuContent` — the minimal menu shown during onboarding:
  "Open Pangolin Setup" + Quit only. (Previously the full menu including
  Resources / More remained visible during setup, which was unintended.)
- `fullMenuContent` — the post‑onboarding menu.

## 5. Bug fixes & cleanup

### Race conditions / lifecycle
- `ResourceCache.refresh()` — token guard against concurrent refreshes.
- `HoverSubmenuRow` — `.onChange(of: keepOpenSignal)` re‑runs `scheduleUpdate`
  so a stale close‑timer cannot fire after the detail‑panel hover state flips.
- `MenuPanelController.deinit` — cleans up `clickMonitor`, `mouseMoveMonitor`,
  `hideTimer`, and `panel.orderOut` (was only releasing `clickMonitor`).
- Status‑icon animation timer — each queued Task checks the current
  `tunnelManager.status` before applying a loading frame, so a frame queued
  before transition to `.connected` cannot overwrite the connected‑badge icon.
- `AnchorReader` — position‑only layout changes (e.g. row moves up after
  logout shortens the menu) now update the anchor; previously the panel
  reopened at the pre‑logout coordinates.
- `AuthManager.hasInitialized` flag prevents repeat `initialize()` on every
  menu open (eliminated the "Loading…" flicker).

### Dead code removed (~600+ lines)
- `OrganizationsMenu`, `AccountsMenu` (replaced by `HoverSubmenuRow` +
  popover content).
- `ConnectButtonItem`, `ConnectMenuRow` (replaced by `ConnectToggleRow`).
- `ResourcesMenu`, `PublicResourceItem`, `PrivateResourceItem` (the original
  4‑depth `NSMenu` version).
- `ResourceSearchView`, `ResourceSearchRow`, `AnyResourceItem` (separate
  search window).
- `MenuItemDropdown` (only used by the deleted Menu structs).
- `MenuViewMode` enum + `viewMode` `@State`, `ResourcesPopoverMode` enum +
  `resourcesPopoverMode` `@State`.
- View‑builder methods: `accountsContent`, `orgsContent`, `moreContent`,
  `resourcesRootContent`, `resourcesPopoverContent`,
  `resourcesListPopoverContent`, `resourcesListMainContent`.
- Dead listener for `NSMenu.didBeginTrackingNotification` (`NSMenu` no longer
  used).
- Duplicate `.pangolinOpenWindow` listener in `MenuBarView`
  (`OpenWindowBridge` handled it).
- Unused `import os.log` in `PangolinApp.swift`.
- Stale comment "5‑minute interval" (actual interval is 3 minutes).
- File deleted: `Pangolin/macOS/UI/Preferences/PreferencesWindowAccessor.swift`.

## 6. Files touched

| File | Change |
| --- | --- |
| `Pangolin/Shared/Models.swift` | New types for resources |
| `Pangolin/Shared/APIClient.swift` | Two new endpoints |
| `Pangolin/Shared/AuthManager.swift` | `hasInitialized` flag, `try?` on notification add |
| `Pangolin/macOS/PangolinApp.swift` | Major rewrite: `AppServices`, `MainMenuController`, `AppWindowsController`, AppDelegate notification observer; all `WindowGroup`s removed |
| `Pangolin/macOS/UI/MenuBarView.swift` | Effectively rewritten (resources, hover submenus, AnchorReader, panel controllers, ResourceCache, all the AppKit helpers) |
| `Pangolin/macOS/UI/Preferences/PreferencesWindow.swift` | Stripped of all window‑management code (now pure SwiftUI content) |
| `Pangolin/macOS/UI/LoginView.swift` | Removed `WindowAccessor`, `configureWindow`, activation‑policy toggling |
| `Pangolin/macOS/UI/OnboardingFlowView.swift` | Removed `OnboardingWindowAccessor`, `configureOnboardingWindow` |
| `Pangolin/macOS/UI/Preferences/PreferencesWindowAccessor.swift` | **Deleted** |

## 7. Net diff characteristics

- **VPN, auth, account management, system extension activation, IPC** —
  functional behavior **unchanged**. `TunnelManager.swift`, system‑extension
  request paths, entitlements, bundle IDs, and the PacketTunnel target
  weren't edited.
- **Visual / interaction shell** is entirely AppKit‑hosted. The SwiftUI views
  remain SwiftUI, but they are no longer responsible for their hosting window.
- **macOS 26 compatibility** — the Preferences‑window layout‑cycle crash is
  fixed; no remaining synchronous `styleMask` mutation during display‑cycle
  observers.

## 8. macOS version compatibility

Deployment target stays at **macOS 14.0**. Every API used in the new code
is available at that level or earlier.

| API | Required | Used in |
| --- | --- | --- |
| `.onChange(of:) { … }` (0‑arg closure) | macOS 14.0 | `MenuBarView.swift` |
| `.onChange(of:) { _, newValue in … }` (2‑arg closure) | macOS 14.0 | `MenuBarView.swift`, `PreferencesWindow.swift` |
| `NavigationSplitView` | macOS 13.0 | `PreferencesWindow.swift` (kept) |
| `.navigationSplitViewColumnWidth(min:ideal:)` | macOS 13.0 | `PreferencesWindow.swift` |
| `LazyVStack(spacing:pinnedViews:)` | macOS 11.0 | `MenuBarView.swift` |
| `Settings { … }` scene | macOS 11.0 | `PangolinApp.swift` |
| `@StateObject`, `@ObservedObject` | macOS 11.0 | throughout |
| `@FocusState` | macOS 12.0 | `MenuBarView.swift` |
| `.task { … }` modifier | macOS 12.0 | `MenuBarView.swift` |
| `Task { @MainActor in … }`, `async/await` | macOS 12.0 | throughout |
| `nonisolated` on functions / `weak var` in actors | Swift 5.5+ | throughout |
| `NSHostingController` / `NSHostingView` subclassing | macOS 10.15 | `MenuBarView.swift` |
| `NSStatusItem`, `NSPanel`, `NSEvent.addGlobalMonitorForEvents` | macOS 10.6+ | `PangolinApp.swift`, `MenuBarView.swift` |
| `NSImage(systemSymbolName:accessibilityDescription:)`, `SymbolConfiguration` | macOS 11.0 | `PangolinApp.swift` (icon badge) |
| `NETunnelProviderManager.loadAllFromPreferences()` (async) | macOS 12.0 | `TunnelManager.swift` (unchanged) |

### Things that *could* misbehave on older macOS (but won't, because target is 14.0)

- The 0‑arg / 2‑arg `.onChange(of:)` forms wouldn't compile on macOS 13. The
  1‑arg deprecated form is intentionally not used anywhere.
- `NavigationSplitView`'s layout behavior in `Preferences` is sensitive to
  the surrounding window's resizability mode. Outer `.frame(minWidth:
  minHeight:)` was intentionally removed because the macOS 26 layout pass
  treated it as a hard constraint on `NSHostingView` and triggered the
  `_postWindowNeedsUpdateConstraints` exception. The fix is benign on
  earlier macOS — `NavigationSplitView`'s own column width minimums still
  enforce a sane minimum size.
- `centerOnScreen(_:)` falls back to `window.center()` if `window.screen`
  and `NSScreen.main` are both nil (i.e. no displays attached). Not expected
  in normal use but covered.

### macOS 26 specifics resolved

- `_postWindowNeedsUpdateConstraints` `NSException` from `NSHostingView`
  layout — fixed by the AppKit‑hosted window controller plus removal of
  synchronous `styleMask` mutation during display‑cycle observers.
- Status‑icon transition race after `Connect` succeeds — fixed by the
  status‑guarded animation timer Task.
