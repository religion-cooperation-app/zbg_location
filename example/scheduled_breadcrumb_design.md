# Scheduled Breadcrumb System — Design Notes

## Current Status

**Branch:** `laventure_2_scheduled`

| Item | Status |
|---|---|
| Heartbeat interval | 360s (6 min) |
| locationUpdateInterval | 360000ms (6 min) |
| distanceFilter | 20m |
| `getCurrentPosition(persist: true)` on every heartbeat | ✓ implemented |
| Headless task heartbeat handling (terminated state GPS fix) | ✗ not yet — native FLP recording covers terminated state but no explicit Dart GPS fix |
| Heartbeat batch sync (`autoSync: false` + manual `sync()`) | ✗ not yet — zbgIngest is called on every heartbeat via native flush |

---

## Goal

Record a location breadcrumb approximately every 5 minutes across all app states:
foreground, background, and terminated. Breadcrumbs must reach Firestore (via
zbgIngest HTTP upload) reliably enough to reconstruct participant location history,
independent of whether the participant is moving or stationary.

The previous motion-detection-based system (`laventure_2`) was reliable when
participants were moving but produced gaps for stationary participants — FBG would
enter stationary mode, reduce polling, and rely on the accelerometer to detect
motion before resuming. A stationary participant at a study site could go hours
without a breadcrumb.

---

## Current Approach (`laventure_2_scheduled`)

### Key FBG config changes

| Setting | Value | Why |
|---|---|---|
| `disableStopDetection` | `true` | Engine never enters stationary mode — no stop/start cycles, heartbeat fires continuously |
| `schedule` | `['1-7 05:00-00:00']` | Tracking window midnight to midnight (effectively always on, with a midnight reset) |
| `scheduleUseAlarmManager` | `true` (Android) | Schedule START/STOP uses `AlarmManager` to pierce Doze, ensuring the window begins on time |
| `startSchedule()` | replaces `start()` | FBG owns the on/off window; app calls `startSchedule()` once |
| `allowIdenticalLocations` | `true` | Time-based FLP deliveries pass through `onLocation` even when stationary (otherwise FBG suppresses identical coords) |

### Flat rate everywhere

Rather than varying heartbeat and distance filter by zone state (inside/near/outside),
all modes use the same values:

| Parameter | Value |
|---|---|
| `heartbeatInterval` | 300s (5 min) |
| `distanceFilter` | 10m |
| `locationUpdateInterval` | 300000ms (5 min) |

Zone state (inside/near/outside) is still tracked and logged for geofence event
writing, but no longer drives sampling frequency.

### Two paths to a breadcrumb

**Path 1 — `onLocation` (primary)**
Android's FusedLocationProvider (FLP) delivers a location when either:
- The device moves ≥ 10m (`distanceFilter`), or
- 5 minutes have elapsed (`locationUpdateInterval`)

With `allowIdenticalLocations: true`, the time-based delivery passes through even
when coords are identical (stationary device). The `_maybeEmitFromFBGLocation` gate
then checks that ≥ 300s have passed since the last emit before writing a breadcrumb.

**Path 2 — `onHeartbeat` (redundancy)**
FBG fires `onHeartbeat` every 300s independently of FLP. The handler uses
`e.location` (FBG's last cached fix). If `e.location` is null it falls back to
`getCurrentPosition(samples: 1)`. This fires even if FLP is deferred.

The `_maybeEmitFromFBGLocation` time gate prevents double-emission when both paths
fire close together.

### Terminated state (Android)

In terminated state (swipe-away), FBG's foreground service is killed. FBG's native
Android `HeadlessTask` (`geoFbgHeadlessTask`) is registered to handle events from
the native layer. It:
- Ignores heartbeat events (returns early — breadcrumbs in terminated state come
  via FBG's own SQLite → HTTP upload path, not the Dart layer)
- Writes geofence ENTER/EXIT/DWELL events to Firestore
- Re-arms Android's Geofencing API on EXIT (re-registers all fences)
- Uses flat 300s/10m — does not read breadcrumb rates from Firestore

FBG buffers location fixes in SQLite when terminated and uploads them to zbgIngest
via HTTP when connectivity is available or when `sync()` is called (e.g. on
homepage visit via `geoFlushBuffer`).

### The Doze problem

Both `locationUpdateInterval` (FLP) and `heartbeatInterval` are best-effort in
Android Doze mode:

- **Light Doze**: most AlarmManager alarms and JobScheduler jobs are deferred
- **Deep Doze**: GPS is throttled; FLP batches to maintenance windows (~1hr,
  stretching longer over time)
- **`scheduleUseAlarmManager`** only protects the schedule START/STOP transition,
  not the sampling rate within the window
- **Samsung**: adds an additional battery management layer on top of stock Doze
  that throttles FLP and kills foreground services more aggressively

**The single most effective fix**: set battery optimization to **Unrestricted** for
the app. This exempts the app from Doze entirely — FLP delivers at the requested
cadence, the heartbeat fires at the configured rate, Samsung's layer backs off.
This should be part of participant onboarding.

---

## Additions and Alternatives

### A — Fresh GPS on every heartbeat

**What changes**: The `onHeartbeat` handler always calls `getCurrentPosition()`
rather than using the stale `e.location` cache. The fallback is already there;
removing the `if (loc == null)` guard makes it unconditional.

**Benefit**: Fresh GPS coords every 5 minutes even when stationary. Eliminates the
one-heartbeat lag where movement has happened but FLP hasn't delivered the updated
position yet.

**Cost**: GPS radio woken every 5 minutes regardless of motion. On Samsung, repeated
`getCurrentPosition()` calls in background triggered foreground service (FGS)
escalation — Android promoting the FGS to a higher-priority type, which increased
battery consumption and caused Samsung to kill the service faster. This is why it
was removed in earlier cleanup. Acceptable if participants have Unrestricted battery
mode set.

---

### B — FCM silent push wakeup

**What it is**: A Cloud Function (`geoWakeupSweep`) sends a data-only FCM message
(content-available: 1) to participants on a schedule. On receipt, `geo_fcm_handler`
calls `fbg.BackgroundGeolocation.sync()` to flush the SQLite buffer and optionally
`getCurrentPosition()` for a fresh fix.

**Benefit**: Server-controlled wakeup interval, independent of the app's internal
timers. Complements the local heartbeat with a network-triggered path.

**Cost**:
- FCM delivery is not guaranteed — messages can be dropped under heavy load or
  delayed by Doze
- iOS: 30-second background window after a silent push; `timeout: 25` required
- Android: FCM itself is not deferred by Doze but the handler execution can be
- Requires server infrastructure and Firestore query to find active participants

Already partially implemented in `geoFirebaseMessagingBackgroundHandler`.

---

### C — iOS Background Fetch

**What it is**: iOS grants periodic background wakeups (~every 15–30 minutes,
OS-controlled interval). `geoBackgroundFetchHeadlessTask` calls `sync()` and
`getCurrentPosition()`.

**Benefit**: No server infrastructure needed. OS-granted wakeup that iOS honours
even in terminated state (not force-quit).

**Cost**:
- Interval is iOS-controlled — minimum is 15 minutes and the OS adjusts it based
  on how often the user opens the app. Cannot be forced to 5 minutes.
- Not available on Android.
- Already implemented in `geo_fcm_handler.dart`.

---

### D — AlarmManager exact alarms (native Android plugin)

**What it is**: A native Kotlin plugin that uses
`AlarmManager.setExactAndAllowWhileIdle()` to schedule a Dart callback every N
minutes. This API can pierce Doze but Android enforces a minimum gap of ~9 minutes
between firings.

**Benefit**: More reliable than FLP's `locationUpdateInterval` in Doze. Can fire
during Doze without waiting for a maintenance window.

**Cost**:
- Requires `SCHEDULE_EXACT_ALARM` permission (Android 12+, user must grant)
- ~9-minute minimum enforced — cannot achieve true 5-minute intervals in deep Doze
- Requires a native Android plugin (not available in Flutter/FBG out of the box)
- Samsung can still throttle these on devices with aggressive power management

---

### E — `allowIdenticalLocations` + lower `locationUpdateInterval`

**What it is**: Keep the current approach but request more frequent FLP updates,
e.g. `locationUpdateInterval: 60000` (1 minute), while keeping the
`_maybeEmitFromFBGLocation` gate at 300s. FLP delivers more often; the gate
discards the extras.

**Benefit**: In non-Doze conditions (foreground, Unrestricted battery), FLP updates
arrive more frequently so the 5-minute breadcrumb is more likely to fall within
seconds of the target time rather than up to `locationUpdateInterval` late.

**Cost**: Higher FLP polling frequency increases battery consumption. In Doze the
interval hint is ignored anyway. Marginal benefit outside Doze where the current
300s interval already works reliably.

---

## Summary

The current approach (`laventure_2_scheduled`) is the correct baseline. The most
impactful single addition is **participant onboarding to Unrestricted battery mode**
— without it, all the mechanisms above degrade in Doze on Samsung. With it, the
current flat-rate approach should achieve consistent 5-minute breadcrumbs in
foreground and background for the vast majority of participants.

For terminated state, the FCM silent push (Option B) is the most reliable
complement that doesn't require native code, since it's a server-initiated wakeup
independent of Doze's local timer restrictions.

---

## Pending Changes and Open Questions

### Native recording in terminated state — contrast with `laventure_2`

In `laventure_2` (motion-detection branch, no schedule), FBG's engine enters
**stationary mode** when the accelerometer detects the device is not moving
(`disableStopDetection: false`, the default). In stationary mode, FBG's native
service drops its FLP subscription — no location updates are delivered, nothing
is written to SQLite. So in terminated state with a stationary participant,
`laventure_2` produces no breadcrumbs at all between geofence events. The engine
only reactivates when the accelerometer triggers a `motionchange:true`.

In `laventure_2_scheduled`, `disableStopDetection: true` keeps the FLP subscription
permanently active within the schedule window. FBG's native Android foreground
service (which survives app termination / swipe-away) holds this subscription and
writes every FLP delivery directly to SQLite — no Dart code required. The native
heartbeat then flushes SQLite → zbgIngest on its own schedule.

This means:
- **Terminated + stationary participant**: `laventure_2` → no breadcrumbs. `laventure_2_scheduled` → ~1 per 6 min from native FLP recording.
- Our Dart `getCurrentPosition(persist: true)` in `onHeartbeat` adds a second explicit
  GPS fix per cycle in foreground/background only. In terminated state it does not run,
  but the native FLP record still appears — the Dart handler is a supplement, not the
  source of the breadcrumb.

### Pending: distanceFilter → 25m

Currently hardcoded at 10m in `_applyMode`. With the heartbeat guaranteeing one fix
per 6 min regardless of movement, the distanceFilter's only role is how often FBG
delivers distance-triggered fixes during movement. 25m reduces onLocation callback
frequency without meaningfully degrading route quality for zone-detection purposes.
Both the FBG config `distanceFilter` and the Dart-layer `distM` constant (used by
`_maybeEmitFromFBGLocation` for `distDue`) should be updated together.

### Pending: heartbeat batch sync

Currently `autoSync: true` is set in the HTTP config. FBG's native heartbeat handler
flushes the SQLite buffer immediately on every heartbeat, regardless of
`autoSyncThreshold`. This means a zbgIngest POST fires every 6 minutes even when only
1 record has accumulated.

To batch:
1. Set `autoSync: false` in `HttpConfig` — locations accumulate in SQLite but are
   never POSTed automatically.
2. Add a heartbeat counter in `TsbgEngine` and call
   `BackgroundGeolocation.sync()` every N heartbeats (e.g. N=5 → one upload every
   30 min with ~5 records per batch).
3. Keep explicit `sync()` calls on app foreground (`geoFlushBuffer`) and on geofence
   events so those are not delayed by the batch window.

Open question: whether 30-min upload latency is acceptable for the study, or whether
geofence-event-triggered sync is sufficient to keep zone-entry data timely while
heartbeat records batch in the background.
