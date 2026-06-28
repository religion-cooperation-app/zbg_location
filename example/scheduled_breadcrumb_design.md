# Scheduled Breadcrumb System — Design Notes

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
