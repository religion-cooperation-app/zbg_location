# Geo Diagnostics — Implementation Plan

Based on the `good-sensor/headless-heartbeat-watchdog` branch files, added to a
`laventure_2_scheduled` baseline app.

---

## How the system works

**Android:** `GeoDiagnosticsScheduler.configure()` registers a `background_fetch` task
(fires on the configured interval via Android AlarmManager/WorkManager, survives
termination) and an FBG `onHeartbeat` listener (debounced by `heartbeatIntervalHours`).
Both paths call `GeoDiagnosticsHttp.recordScheduledSnapshot()` → reads permission/location
state (no GPS fix, read-only) → compares to last SQLite snapshot → if changed, POSTs to
`geoDiagnosticsIngest` Cloud Function → queues in SQLite if POST fails.

**iOS:** `GeoDiagnosticsScheduler.configure()` returns `'unsupported_platform'` immediately.
iOS gets no scheduled diagnostics from this system. If iOS coverage is needed later, add
diagnostics calls to `geoBackgroundFetchHeadlessTask` in `geo_fcm_handler.dart` — that is
a separate, optional step.

**Foreground flush:** `flushGeoDiagnosticsHttp()` on app open retries any SQLite-queued
POSTs from background failures. Cheap (single SQLite read) when queue is empty.

### No changes to existing files

`geo_bootstrap.dart` wraps its `BackgroundFetch.configure()` in `if (Platform.isIOS)`.
`GeoDiagnosticsScheduler.configure()` opens with `if (!Platform.isAndroid) return`.
They operate on separate platforms — no registration conflict, no changes needed to
`geo_bootstrap.dart` or `geo_fcm_handler.dart`.

---

## Step 1 — Copy 2 new custom code files from the diagnostics branch

Both come from `origin/good-sensor/headless-heartbeat-watchdog:example/` and go into
FlutterFlow as **Custom Code Files** (not actions).

### `geo_diagnostics_http.dart`

Copy with one modification to the clamps inside `configure()`:

```dart
// Original (too restrictive for 3-day cadence):
'fetchIntervalMinutes': fetchIntervalMinutes.clamp(15, 1440),
'heartbeatIntervalHours': heartbeatIntervalHours.clamp(1, 24),
'dailySnapshotHours': dailySnapshotHours.clamp(1, 168),

// Change to:
'fetchIntervalMinutes': fetchIntervalMinutes.clamp(15, 10080),   // allow up to 7 days
'heartbeatIntervalHours': heartbeatIntervalHours.clamp(1, 168),  // allow up to 7 days
'dailySnapshotHours': dailySnapshotHours.clamp(1, 168),          // unchanged
```

Everything else in the file is unchanged.

### `geo_diagnostics_scheduler.dart`

Copy verbatim, no changes. Android-only. Contains the
`@pragma('vm:entry-point') geoDiagnosticsBackgroundFetchHeadlessTask` function and
the FBG `onHeartbeat` listener registration.

---

## Step 2 — Copy 3 new custom actions from the diagnostics branch

All from `origin/good-sensor/headless-heartbeat-watchdog:example/`, copied verbatim.

| Action file | FlutterFlow action name | Args | Returns |
|---|---|---|---|
| `configure_geo_diagnostics_http.dart` | `configureGeoDiagnosticsHttp` | `regionId: String`, `endpointUrl: String`, `apiKey: String`, `fetchIntervalMinutes: int?`, `heartbeatIntervalHours: int?`, `dailySnapshotHours: int?` | `String` |
| `configure_geo_diagnostics_scheduled_audit.dart` | `configureGeoDiagnosticsScheduledAudit` | none | `String` |
| `flush_geo_diagnostics_http.dart` | `flushGeoDiagnosticsHttp` | `limit: int` | `int` |

`uid` is **not** a parameter — `geo_diagnostics_http.dart`'s `configure()` reads it
directly from `FirebaseAuth.instance.currentUser?.uid`.

`configureGeoDiagnosticsScheduledAudit` **must** be called after
`configureGeoDiagnosticsHttp` — it reads the fetch interval from SQLite (written by
`configure()`).

---

## Step 3 — No changes to existing files

`geo_bootstrap.dart`, `geo_fcm_handler.dart`, and `geoStartFromConfig.dart` are
unchanged.

---

## Step 4 — Firestore: add two fields to `appConfig/runtime`

```
geo_diag_endpoint_url:  "<deployed geoDiagnosticsIngest function URL>"
geo_diag_api_key:       "<API key the Cloud Function validates>"
```

All downstream headless reads come from SQLite — no Firestore access needed in
terminated state.

---

## Step 5 — FlutterFlow wiring

### Sign-in action chain (after `geoStartFromConfig` returns `'success'`)

1. Firestore Get → `appConfig/runtime` (reuse existing read if available)
2. Call `configureGeoDiagnosticsHttp`:
   - `regionId` — same value passed to `geoStartFromConfig`
   - `endpointUrl` — `appConfig/runtime.geo_diag_endpoint_url`
   - `apiKey` — `appConfig/runtime.geo_diag_api_key`
   - `fetchIntervalMinutes: 4320` (3 days)
   - `heartbeatIntervalHours: 72` (3 days)
   - `dailySnapshotHours: 72` (3 days)
3. Call `configureGeoDiagnosticsScheduledAudit` (no args)

### HomePage OnPageLoad

4. Call `flushGeoDiagnosticsHttp(limit: 20)`

---

## Step 6 — `index.js`: change alert sweep schedule

```js
// Change:
exports.geoPermissionAlertSweep = onSchedule('every 8 hours', async () => {
// To:
exports.geoPermissionAlertSweep = onSchedule('every 72 hours', async () => {
```

Deploy after editing. No other Cloud Function changes — `geoDiagnosticsIngest` already
exists and handles incoming POSTs correctly.

---

## Platform coverage

| Platform | Mechanism | Frequency |
|---|---|---|
| Android background | `background_fetch` headless task | Every 3 days (Android scheduler) |
| Android background | FBG `onHeartbeat` listener (debounced) | Every 3 days |
| Android foreground | `flushPending()` on app open | Every open; cheap if queue empty |
| iOS | Not covered by this plan | Extend `geoBackgroundFetchHeadlessTask` later if needed |

## Estimated cost at 3-day cadence

- ~10 SQLite reads + ~1 HTTP POST per user per month (when state changes)
- 0 Firestore reads from headless/background
- 1 Firestore write per POST (via `geoDiagnosticsIngest`)
- `geoPermissionAlertSweep` runs once every 3 days instead of 90× per month
