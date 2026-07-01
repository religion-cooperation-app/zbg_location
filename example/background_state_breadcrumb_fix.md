# Background State Breadcrumb Fix

## Problem

When the app transitions from terminated state to background state, FBG resets its
native-to-Dart bridge ("Cleared callbacks" in the log). After this reset, all Dart
listeners registered via `onHeartbeat`, `onLocation`, `onGeofence`, and
`onMotionChange` are orphaned — the native FBG service continues running and firing
events, but no Dart handler receives them.

The root cause is a one-time guard in `TsbgEngine.setConfig()`:

```dart
if (!_listenersAttached) {
  _attachListeners();
  _listenersAttached = true;
}
```

`_listenersAttached` is set to `true` after the first registration and never reset.
When FBG clears its callbacks on resume, `_listenersAttached` is still `true`, so
`_attachListeners()` never runs again. From this point forward:

- `onHeartbeat` does not fire → no `getCurrentPosition(persist: true)` → no
  breadcrumb via the Dart path
- `onLocation` does not fire → no `_maybeEmitFromFBGLocation` → no Dart breadcrumb
- `onGeofence` does not fire → geofence events are not written to Firestore from
  the Dart path
- `onMotionChange` does not fire → `_applyMode()` is never called on motion state
  transitions

Confirmed in logs (`background-geolocation (84) Wcp Jul 1.log`): the 12:45–13:06
background window shows heartbeat alarms firing (`❤️` + OneShot entries) but zero
`getCurrentPosition` calls, zero `💾 ✅` SQLite writes, and zero HTTP POSTs. On app
open at 13:06:41, `HTTP Service (count: 0)` confirms nothing accumulated in SQLite
during the entire background window.

This does not affect terminated state. In terminated state the Dart VM is dead
entirely — `geoFbgHeadlessTask` handles all events in its own isolate, independently
of `TsbgEngine` and `GeoBootstrap`. The headless path is unaffected by this fix.

---

## Fix

Two files are changed.

### 1. `zbg_location/lib/tsbg_engine.dart`

**Add `reattachListeners()` method** after `flushBuffer()`:

```dart
/// Re-attaches FBG Dart listeners after the native layer clears them.
/// FBG clears its native-to-Dart bridge on every resume from terminated state
/// ("Cleared callbacks" in the log), orphaning all onHeartbeat/onLocation/
/// onGeofence/onMotionChange handlers. Call this from
/// WidgetsBindingObserver.didChangeAppLifecycleState on resumed to restore them.
void reattachListeners() {
  if (!_started) return;
  fbg.BackgroundGeolocation.removeListeners();
  _listenersAttached = false;
  _attachListeners();
  _listenersAttached = true;
}
```

**Line-by-line:**

- `if (!_started) return` — no-ops before `start()` has ever been called. Prevents
  a spurious `removeListeners` + `_attachListeners` on the very first app open before
  the engine is running.
- `fbg.BackgroundGeolocation.removeListeners()` — FBG's own API for clearing all
  registered Dart callbacks. Called first to guarantee a clean slate before
  re-registering, in case any stale partial registrations remain.
- `_listenersAttached = false` — resets the guard so `_attachListeners()` runs
  unconditionally. Without this reset, `_attachListeners()` would not be entered
  (the guard checks `!_listenersAttached` at the call site in `setConfig()`).
- `_attachListeners()` — re-registers all Dart callbacks: `onHeartbeat`,
  `onLocation`, `onPowerSaveChange`, `onProviderChange`, `onEnabledChange`,
  `onGeofence`, `onMotionChange`.
- `_listenersAttached = true` — restores the guard so any subsequent `setConfig()`
  call (e.g. a live Firestore config update) does not attempt another registration
  on top of the freshly-attached listeners.

---

### 2. `example/geo_bootstrap.dart`

**Four changes:**

#### a) New import

```dart
import 'package:flutter/widgets.dart';
```

Brings in `WidgetsBindingObserver` and `WidgetsBinding`. Added after
`dart:io` and before `package:cloud_firestore`.

#### b) Class declaration — add `WidgetsBindingObserver` mixin

```dart
// before
class GeoBootstrap {

// after
class GeoBootstrap with WidgetsBindingObserver {
```

Makes `GeoBootstrap` a Flutter lifecycle observer. No base class change; `with` is
sufficient. The singleton pattern (`GeoBootstrap._()`) is unchanged.

#### c) New field `_observerRegistered`

```dart
bool _observerRegistered = false;
```

Added alongside the other bool fields (`_starting`, `_inside`). Guards the
`addObserver(this)` call so it is only made once per singleton lifetime. Without
this guard, a second call to `startFromFirestore` (e.g. from a homepage action
running twice) would register a second observer and cause
`didChangeAppLifecycleState` to fire twice per lifecycle event, resulting in a
double `removeListeners` + `_attachListeners` cycle.

#### d) Observer registration + `didChangeAppLifecycleState` override

At the top of `_startFromFirestoreInner`:

```dart
if (!_observerRegistered) {
  WidgetsBinding.instance.addObserver(this);
  _observerRegistered = true;
}
```

`addObserver(this)` registers the singleton with Flutter's binding. After this
single call, Flutter invokes `didChangeAppLifecycleState` automatically on every
app lifecycle transition for the lifetime of the app. Placed at the very top of
`_startFromFirestoreInner` so the observer is active as early as possible,
regardless of whether subsequent startup steps succeed or throw.

The override, placed before `stop()`:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _engine.reattachListeners();
  }
}
```

`AppLifecycleState.resumed` fires every time the app comes to the foreground from
any prior state (terminated, background, or paused). This is the same moment at
which FBG performs its "Cleared callbacks" bridge reset on the native side. By
calling `reattachListeners()` here, Dart listeners are restored immediately after
the reset, before the user can background the app again or any FBG event fires into
the now-dead bridge.

Only `resumed` is handled. No action is taken on `paused`, `inactive`,
`detached`, or `hidden` — these do not require listener re-registration.

---

## Interaction with `setConfig()` and `startFromFirestore()`

`setConfig()` is called by the Firestore config listener inside
`_startFromFirestoreInner` and on every live config update. It contains:

```dart
if (!_listenersAttached) {
  _attachListeners();
  _listenersAttached = true;
}
```

The ordering on every resume from terminated state is:

1. `didChangeAppLifecycleState(resumed)` fires (OS-level, before any page renders)
2. `reattachListeners()` runs → `removeListeners()` → `_attachListeners()` →
   `_listenersAttached = true`
3. Homepage renders → any `geoStartFromFirestore` custom action runs →
   `startFromFirestore()` → `setConfig()` → `_listenersAttached == true` → **skips
   `_attachListeners()`**

There is no double-registration. The lifecycle callback always wins the race because
Flutter fires it before Dart page logic runs.

On first-ever startup (app has never run before), `reattachListeners()` is a no-op
because `_started == false`. `setConfig()` performs the initial registration
normally.

---

## What this does NOT affect

- **Terminated state breadcrumbs**: unaffected. In terminated state the Dart VM is
  dead — no lifecycle observer fires, no Dart code runs. `geoFbgHeadlessTask`
  handles heartbeat and geofence events entirely independently in its own isolate.
  The headless path (`getCurrentPosition(persist:true)` + `sync()`) continues to
  work exactly as before.

- **Foreground state breadcrumbs**: unaffected. Listeners are already alive in
  foreground; `reattachListeners()` on resume simply refreshes them to the same
  state they were already in.

- **Geofence re-arming**: unaffected. Android geofence re-arming on EXIT is handled
  natively by FBG and confirmed separately in `geoFbgHeadlessTask`. The Dart-side
  `onGeofence` handler in `GeoBootstrap` now fires correctly in background state
  after this fix, which is an improvement for geofence event Firestore writes when
  the app is backgrounded but not terminated.

---

## Motion-to-still transitions in background state

Before this fix: `onMotionChange` was dead in background state, so `_applyMode()`
was never called when the device stopped after a walk. FBG's native heartbeat would
restart correctly (the native service handles `motionchange: false` itself), but the
Dart sampling-mode state would be stale.

After this fix: `onMotionChange` is alive in background state. When FBG fires
`motionchange: false` after the 30-minute `stopTimeout`, `_applyMode()` runs
correctly and updates `heartbeatInterval`, `distanceFilter`, and
`locationUpdateInterval` for the new mode. Zone-based rate changes now work
correctly in background state.

---

## Diagnostic logging

Three log lines are written to both **Crashlytics** and the **FBG verbose log file**
(the `.log` files shared for debugging). FBG logger entries appear inline with FBG's
own events with a `[D]` prefix.

### In `geo_bootstrap.dart` — `didChangeAppLifecycleState`

```
[D] lifecycle: resumed → reattachListeners
```

Confirms Flutter's `WidgetsBindingObserver` fired on app resume and that
`reattachListeners()` was called. If this line never appears in the FBG log, the
observer was not registered or `AppLifecycleState.resumed` did not fire.

### In `tsbg_engine.dart` — `reattachListeners()`

```
[D] reattachListeners: start
[D] reattachListeners: done
```

`start` appearing without `done` would indicate a crash inside `removeListeners()`
or `_attachListeners()`. Both appearing confirms the bridge was cleared and all
listeners re-registered successfully.

### Confirming the fix worked end-to-end

After seeing the three lines above, look for the existing Crashlytics log in
`onHeartbeat`:

```
hb mode=... ts=...
```

This is Crashlytics-only (not in the FBG verbose log). The FBG verbose log already
writes its own `❤️ HeartbeatEvent` entry natively — if that entry is followed by a
`getCurrentPosition` call in the same background window (i.e. after
`reattachListeners: done`), the Dart heartbeat handler is executing and the fix is
confirmed working end-to-end.

### What the log sequence should look like after the fix

In a background window following a terminated-state period:

```
[D] lifecycle: resumed → reattachListeners   ← GeoBootstrap lifecycle callback
[D] reattachListeners: start                 ← TsbgEngine begins re-registration
[D] reattachListeners: done                  ← all listeners restored
... (some time passes, FBG heartbeat alarm fires) ...
❤️ HeartbeatEvent ...                        ← FBG native heartbeat
getCurrentPosition ...                        ← Dart onHeartbeat handler executed
💾 ✅ ...                                     ← location persisted to SQLite
```

Before the fix, the `getCurrentPosition` and `💾 ✅` lines were absent during any
background window that followed a terminated-state period.
