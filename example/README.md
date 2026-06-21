# FlutterFlow Integration Layer

These files are the glue between the `zbg_location` package and a FlutterFlow project. They are not part of the package itself — they live in the FlutterFlow project as custom code files and call into the package via the `GeoBootstrap` singleton.

## Compatibility note

Files in this folder require the `zbg_location` package at the version in this branch (`good-sensor/headless-heartbeat-watchdog`) or later. The following APIs introduced in this branch are **not** available at `stable/e5be1b0-paired@2abdbfa` or earlier:

- `TsbgEngine.forceMovingPace()`
- `TsbgEngine.logNativeGeofenceInventory()`
- `GeoDiagnosticsWriter.readHeartbeatWatchdogRun()`
- `GeoDiagnosticsWriter.storeHeartbeatWatchdogRun()`
- `LocationSample.activityType`, `.activityConfidence`, `.fbgIsMoving`, `.fbgEvent`

If you revert `zbg_location` to `2abdbfa`, you must also revert `geo_bootstrap.dart` and `geo_fcm_handler.dart` to their `june_11_zbg_mods` versions and remove all files listed in the "Diagnostics stack" section below (they have no equivalent at that version).

---

## Core custom code files

### `geo_bootstrap.dart`
The bootstrap orchestrator. A singleton (`GeoBootstrap.instance`) that:
- Reads study configuration (`appConfig/runtime`) and geofence definitions (`regions/{regionId}/geofences`) from Firestore at session start, with live listeners that propagate updates without an app restart
- Configures and starts `TsbgEngine` (the FBG wrapper in the package)
- Subscribes to location and geofence event streams and writes breadcrumbs and geofence events to Firestore
- Registers background wakeup handlers (FCM silent push, iOS background fetch, Android FBG headless task)
- Broadcasts zone state changes via `onZoneChange` for consumption by the BLE proximity system
- Writes `geo_running`, `geo_session_started`, and `geo_session_stopped` to the user document and to `geoSessions/{uid}` for server-side monitoring
- Supports runtime config refresh (`refreshConfigFromMapForced`) and geofence refresh (`refreshGeofencesFromFirestore`) without a full restart
- Registers as a `WidgetsBindingObserver` to trigger geofence refresh on app resume

Copy to: `lib/custom_code/geo_bootstrap.dart` in your FlutterFlow project.

### `geo_fcm_handler.dart`
FCM background message handler, iOS background-fetch headless task, and Android FBG headless task. Responsibilities:
- Headless heartbeat watchdog: checks SQLite for last heartbeat timestamp, calls `changePace(true)` if FBG has been stationary beyond threshold
- Near-zone and inner-zone force-wake: calls `forceMovingPace()` on ENTER of `_near` and inner fences when FBG is stationary
- FCM `refresh_geofences` message routing: triggers `_headlessFcmRefreshGeofences` on `msgType == 'refresh_geofences'`
- Headless MOTIONCHANGE, ACTIVITYCHANGE, CONNECTIVITYCHANGE, and LOCATION event logging
- Re-arms geofences on EXIT and writes geofence version stamps

Copy to: `lib/custom_code/geo_fcm_handler.dart` in your FlutterFlow project.

---

## Diagnostics stack

These three files form the diagnostics layer. They have no equivalent prior to this branch. If reverting to `2abdbfa`, delete all three and the six custom actions below that depend on them.

### `geo_diagnostics.dart`
Foreground diagnostics class (`GeoDiagnostics`). Handles:
- Change-diffing of FBG provider state, power-save state, and enabled state in the foreground (distinct from the headless path which goes through `geo_diagnostics_http.dart`)
- Daily system check (`runDailySystemCheckIfDue`): writes a snapshot of GPS permission, battery, FBG state, and native geofence count to `geo_diagnostics/current` and `geo_events`
- `updateUserClientEnvironmentIfChanged`: writes app version, OS version, and device model to the user doc when they change

Copy to: `lib/custom_code/geo_diagnostics.dart`.

Wired into the app via:
- `run_daily_geo_system_check_if_due.dart` — called on homepage load
- `update_user_client_environment_if_changed.dart` — called on app startup

### `geo_diagnostics_http.dart`
Headless-safe diagnostics helper (`GeoDiagnosticsHttp`). Handles:
- SQLite queue for diagnostic events that cannot safely write Firestore from a headless isolate
- HTTP POST to `geoDiagnosticsIngest` Cloud Function (avoids direct Firestore SDK from background)
- `recordProviderChange`, `recordHeartbeatSnapshot`, `recordScheduledSnapshot`
- `flushPending`: drains the SQLite queue when the app is in the foreground

Copy to: `lib/custom_code/geo_diagnostics_http.dart`.

Wired into the app via:
- `configure_geo_diagnostics_http.dart` — called on sign-in to set endpoint URL, API key, and intervals
- `configure_startup_background_systems.dart` — called on app startup to configure both this and the lean background flush scheduler
- `flush_geo_diagnostics_http.dart` — called on homepage load to drain the SQLite queue

### `geo_diagnostics_scheduler.dart`
Android `background_fetch` scheduler (`GeoDiagnosticsScheduler`). Configures a periodic background task (default 15 min) that:
- Takes a `getCurrentPosition` snapshot
- Writes it via `GeoDiagnosticsHttp.recordScheduledSnapshot` to the SQLite queue for later HTTP flush
- Runs even when the app is terminated (Android background fetch task survives termination longer than FBG heartbeat on some OEMs)

Copy to: `lib/custom_code/geo_diagnostics_scheduler.dart`.

Wired into the app via:
- `configure_geo_diagnostics_scheduled_audit.dart` — called on app startup

---

## Custom actions

### `geoStartFromConfig.dart` / `geo_start_from_config.dart`
Calls `GeoBootstrap.instance.startFromFirestore(regionId)`. Returns `'success'` or an error string. Call on sign-in and conditionally on the homepage (gated by `isBreadcrumbStale`).

Copy to: `lib/custom_code/actions/geo_start_from_config.dart`.

### `geostop.dart`
Calls `GeoBootstrap.instance.stop()`. Returns `'success'` or an error string. Call on sign-out.

Copy to: `lib/custom_code/actions/geostop.dart`.

### `apply_app_config_runtime.dart`
Reads `appConfig/runtime` from Firestore and calls `GeoBootstrap.instance.refreshConfigFromMapForced(data)` to apply a new sampling config without restarting the geo session. Returns a JSON status string. Called from the app's admin config screen.

Copy to: `lib/custom_code/actions/apply_app_config_runtime.dart`.

Requires: `GeoBootstrap.refreshConfigFromMapForced()` — added in this branch, **not present at `2abdbfa`**.

### `geo_refresh_geofences.dart`
Calls `GeoBootstrap.instance.refreshGeofencesFromFirestore(regionId)` to pull the latest geofence definitions from Firestore and re-arm the native FBG geofence set without a full restart. Returns `'success'` or an error string. Called from the app's admin screen and from the FCM `refresh_geofences` push path.

Copy to: `lib/custom_code/actions/geo_refresh_geofences.dart`.

Requires: `GeoBootstrap.refreshGeofencesFromFirestore()` — added in this branch, **not present at `2abdbfa`**.

### `configure_geo_diagnostics_http.dart`
Calls `GeoDiagnosticsHttp.configure(regionId, endpointUrl, apiKey, ...)` to initialize the HTTP diagnostics queue with the Cloud Function endpoint and polling intervals. Called on sign-in after the region is known.

Copy to: `lib/custom_code/actions/configure_geo_diagnostics_http.dart`.

### `configure_geo_diagnostics_scheduled_audit.dart`
Calls `GeoDiagnosticsScheduler.configure()` to register the Android `background_fetch` periodic audit task. Called once on app startup.

Copy to: `lib/custom_code/actions/configure_geo_diagnostics_scheduled_audit.dart`.

### `configure_startup_background_systems.dart`
Umbrella startup action that configures both `GeoDiagnosticsHttp` (if a stored region ID is found in SQLite) and the lean background maintenance scheduler. Reads the cached region ID from SQLite so it can configure diagnostics even before the user has signed in. Called early in the app startup sequence.

Copy to: `lib/custom_code/actions/configure_startup_background_systems.dart`.

### `flush_geo_diagnostics_http.dart`
Calls `GeoDiagnosticsHttp.flushPending(limit)` to drain the SQLite queue of unsent diagnostic events via HTTP POST. Called on homepage load so events queued while headless are delivered when the app comes to foreground.

Copy to: `lib/custom_code/actions/flush_geo_diagnostics_http.dart`.

### `run_daily_geo_system_check_if_due.dart`
Calls `GeoDiagnostics.runDailySystemCheckIfDue()`. Runs at most once per 24 hours (gated internally by SQLite timestamp). Captures a full system snapshot (GPS permission, battery optimization, FBG enabled state, native geofence count) and writes it to Firestore `geo_diagnostics/current` and `geo_events`. Called on homepage load.

Copy to: `lib/custom_code/actions/run_daily_geo_system_check_if_due.dart`.

### `update_user_client_environment_if_changed.dart`
Calls `GeoDiagnostics.updateUserClientEnvironmentIfChanged()`. Writes app version, build number, OS version, and device model to the Firestore user document when any of them change. Called on app startup.

Copy to: `lib/custom_code/actions/update_user_client_environment_if_changed.dart`.

---

## Additional custom files (project-specific, not included here)

- `zbg_firestore_adapter.dart` — `WriteFn` adapter that bridges `FirestoreWriter` to the Firebase SDK available in FlutterFlow
- `lean_background_maintenance_scheduler.dart` — Android background_fetch scheduler for offline queue flushing (used by `configure_startup_background_systems`)

---

## Firestore data model

The integration layer expects the following Firestore structure:

```
appConfig/runtime              — sampling rates, distance filters, dwell thresholds, disableStopDetection
appConfig_regions/{regionId}   — region existence check
regions/{regionId}/geofences   — geofence definitions (circle: center.lat, center.lng, radius_m)
users/{uid}                    — user document (geo_running, geo_session_started, geo_session_stopped, last_breadcrumb_ts, app_version, os_version, device_model)
geoSessions/{uid}              — geo session tracking document (written at step 7 of bootstrap)
regions/{regionId}/breadcrumbs — GPS fix documents written by zbgIngest and Dart path
geofence_events                — ENTER/EXIT/DWELL event documents
geo_events                     — diagnostic event log (provider changes, daily snapshots)
geo_diagnostics/current        — latest system snapshot document (written by daily check)
```
