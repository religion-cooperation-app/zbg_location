# Background State Breadcrumb Fix

**Branch:** `laventure_2_scheduled`

---

## Problem

When the app opens from a terminated state, FBG resets its native-to-Dart bridge
("Cleared callbacks" in the log). This orphans any Dart listeners registered from a
previous session. On a **normal daily app open** — one where `startFromFirestore`
does not run (no stale breadcrumbs, no permission change, no config change) — Dart
listeners are never re-registered, so FBG native heartbeats that fire while the app
is backgrounded are silently dropped.

The mechanics:

- `TsbgEngine._attachListeners()` is only called from `setConfig()`, which is only
  called from `startFromFirestore`
- `startFromFirestore` only runs when `permissionUpdated == true` in the FlutterFlow
  homepage action flow — not on every app open
- On a normal daily open, `_started = false`, `_listenersAttached = false`, and
  `_attachListeners()` is never called
- FBG heartbeat fires in background → native service fires alarm → "TERMINATE_EVENT
  ignored (MainActivity is still active)" → no headless task → no Dart handler → event
  dropped

Evidence in `background-geolocation (85).log`: heartbeat alarms fire during the
16:41–16:49 background window with zero `getCurrentPosition` calls, zero SQLite
writes, and zero HTTP POSTs.

### What the broken fix also introduced (regression)

An earlier attempt added `with WidgetsBindingObserver` to `GeoBootstrap` and called
`_engine.reattachListeners()` on every `AppLifecycleState.resumed`. This made things
worse:

- `reattachListeners()` called `BackgroundGeolocation.removeListeners()` (which
  returns Futures that are not awaited) then immediately called `_attachListeners()`
- The subscription cancellations did not settle before re-registration, so old and
  new listeners coexisted → 5x `getCurrentPosition` per heartbeat → corrupted bridge
- Background→foreground transitions (no "Cleared callbacks") also triggered the
  re-registration unnecessarily
- Log 85 shows exactly this: 5x `getCurrentPosition` per heartbeat in the 15:18–15:36
  background window, followed by a broken bridge from 16:18 onward

---

## Root cause summary

**FBG listeners must be registered on every app open**, not just when
`startFromFirestore` runs. The hook that runs on every app open already exists:
`_AppSessionTracker._onForeground()` in `register_lifecycle_tracker.dart`, called
from `initState` on the homepage.

---

## Fix

### What the fix does

Add `TsbgEngine.ensureListeners()` — a simple, idempotent method that registers
FBG Dart listeners if not already registered in this Dart VM session. Call it from
`_AppSessionTracker._onForeground()` so it runs on every app open.

**No `removeListeners()` is needed.** The `_listenersAttached` flag is `false` on
every fresh Dart VM (FBG has already cleared callbacks by the time `_onForeground()`
fires), so we just call `_attachListeners()` directly. On background→foreground, the
flag is `true` (listeners are still alive), so `ensureListeners()` is a no-op.

### Files changed

---

### 1. `zbg_location/lib/tsbg_engine.dart`

**Replace `reattachListeners()` with `ensureListeners()`:**

```dart
/// Registers FBG Dart event listeners if not already registered this session.
/// Safe to call before ready() or start() — only subscribes to EventChannels.
/// Idempotent: guarded by _listenersAttached so duplicate calls are no-ops.
/// Called on every app open via registerLifecycleTracker so background
/// heartbeats reach Dart handlers regardless of whether startFromFirestore ran.
void ensureListeners() {
  if (_listenersAttached) return;
  _attachListeners();
  _listenersAttached = true;
}
```

**Add entry log to `onHeartbeat`:**

```dart
fbg.BackgroundGeolocation.onHeartbeat((fbg.HeartbeatEvent e) async {
  FirebaseCrashlytics.instance.log('onHeartbeat: dart handler entered');
  // ... rest unchanged
```

This marker distinguishes "native heartbeat fired" (visible in FBG verbose log as
`❤️`) from "Dart handler ran" (visible in Crashlytics). If the marker is absent
after a heartbeat, `ensureListeners()` did not register the handler.

---

### 2. `example/geo_bootstrap.dart`

**Remove** the broken lifecycle observer approach:
- Remove `with WidgetsBindingObserver`
- Remove `import 'package:flutter/widgets.dart'`
- Remove `bool _observerRegistered = false`
- Remove the `addObserver(this)` block from `_startFromFirestoreInner`
- Remove the `didChangeAppLifecycleState` override

**Add** public forwarding method:

```dart
/// Ensures FBG Dart listeners are registered in this Dart VM session.
/// Delegates to TsbgEngine.ensureListeners() — idempotent, safe before start().
/// Call from registerLifecycleTracker on every app open.
void ensureListeners() => _engine.ensureListeners();
```

---

### 3. `sparrc/lib/custom_code/actions/register_lifecycle_tracker.dart`

**Add import:**

```dart
import '/custom_code/geo_bootstrap.dart';
```

**Add call at top of `_onForeground()`:**

```dart
void _onForeground() {
  if (_isInForeground) return;
  _isInForeground = true;
  GeoBootstrap.instance.ensureListeners();  // ← added
  final uid = FirebaseAuth.instance.currentUser?.uid;
  // ... rest unchanged
```

`_onForeground()` fires via `register()` in homepage `initState` on every app open
from terminated state, and via `didChangeAppLifecycleState(resumed)` on every
background→foreground transition. The `_isInForeground` guard ensures it fires once
per foreground entry. `ensureListeners()` is idempotent so both code paths are safe.

---

## How it solves the problem

On a normal daily app open (no `startFromFirestore`):

1. App opens from terminated
2. FBG fires "Cleared callbacks" (very early, native side)
3. Flutter starts → homepage `initState` → `registerLifecycleTracker()`
4. `_onForeground()` → `GeoBootstrap.instance.ensureListeners()`
5. `_listenersAttached = false` → `_attachListeners()` → listeners registered
6. `_listenersAttached = true`
7. User backgrounds app → Dart VM stays alive → listeners remain registered
8. FBG heartbeat fires → `onHeartbeat` Dart handler executes
9. `getCurrentPosition(persist: true)` → saved to SQLite
10. FBG `autoSync` uploads via zbgIngest → Firestore breadcrumb written

When `startFromFirestore` also runs (stale breadcrumbs, config change):

- `setConfig()` checks `!_listenersAttached` → already `true` → skips `_attachListeners()`
- No double-registration
- `startFromFirestore` sets up `_cfg`, `_locSub`, `_writer` → real-time Dart emission
  to Firestore also works (not just SQLite-buffered)

On background→foreground (same Dart VM session):

- `_onForeground()` → `ensureListeners()` → `_listenersAttached = true` → no-op
- No `removeListeners()` called, no listener churn

---

## What this does NOT affect

- **Terminated state breadcrumbs**: unaffected. In terminated state the Dart VM is
  dead — `geoFbgHeadlessTask` handles events in its own isolate independently.

- **Foreground state breadcrumbs**: unaffected. Listeners are alive; `ensureListeners()`
  is a no-op.

- **`startFromFirestore` when it does run**: unaffected. `setConfig()` still skips
  `_attachListeners()` when `_listenersAttached = true`, preventing double-registration.

---

## Confirming the fix end-to-end

After deploying, look for this Crashlytics sequence during a background window on a
normal app open (no `startFromFirestore`):

```
onHeartbeat: dart handler entered    ← Dart handler executed
hb mode=... ts=...                   ← existing mode/time log
```

In the FBG verbose log, the heartbeat should now be followed by `getCurrentPosition`
and `💾 ✅` entries:

```
❤️ HeartbeatEvent ...
getCurrentPosition ...
💾 ✅ ...
```

Before the fix: `getCurrentPosition` and `💾 ✅` were absent on normal daily opens
during any background window.
