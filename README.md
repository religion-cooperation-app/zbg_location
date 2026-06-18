# zbg_location

A Flutter package implementing continuous GPS tracking and geofence monitoring for longitudinal research applications. Built as a wrapper around [flutter_background_geolocation](https://pub.dev/packages/flutter_background_geolocation) (FBG) with adaptive sampling, dwell detection, and a Firebase Cloud Functions ingestion endpoint.

Developed for the SPARRC project (Social Proximity And Religious Ritual Capture) at the Experimental Anthropology Lab, University of Connecticut.

## Features

- **Adaptive sampling** — GPS sampling rate and distance filter adjust automatically based on proximity to study zones (inside / near / outside), minimising battery drain while maintaining precision where it matters
- **Geofence monitoring** — circular geofence zones with configurable ENTER, EXIT, and DWELL detection; live zone definitions streamed from Firestore with no app restart required
- **Dwell detection** — fires a DWELL event after a configurable minimum time inside a zone, with optional repeating milestone events
- **Dual write paths** — FBG's native HTTP transport delivers fixes to the Cloud Function even in terminated state; a Dart-layer path provides redundant delivery in foreground and background
- **Terminated-state coverage** — Android FBG headless task handles geofence events and re-arms Android's Geofencing API on EXIT when the app process is not running; iOS background fetch and FCM silent push provide periodic wakeups
- **Geofence-only mode** — disables continuous GPS breadcrumbs and uses FBG's `startGeofences()` API, recording only zone entry/exit events for cost and battery reduction
- **Live remote configuration** — all sampling rates, distance filters, dwell thresholds, and mode flags are read from a Firestore document and updated in real time without restarting the app

## Architecture

The package exposes a single engine class (`TsbgEngine`) that wraps FBG and manages:
- FBG configuration and lifecycle (`start`, `stop`, `startGeofences`)
- Per-mode distance filter and heartbeat interval application
- Geofence registration and re-registration
- Dwell milestone tracking
- Native HTTP upload to the zbgIngest Cloud Function endpoint
- Zone context tagging on FBG's HTTP extras so every breadcrumb carries the current zone identifier

The `TsbgEngine` is orchestrated by `GeoBootstrap` (see `example/`), a singleton that lives in the FlutterFlow custom code layer and handles Firestore reads, stream subscriptions, and user document writes.

## Package structure

```
lib/
  api.dart              — RuntimeConfig, GeofenceDef, GeofenceEvent, LocationSample
  tsbg_engine.dart      — core FBG wrapper and adaptive sampling logic
  writers.dart          — FirestoreWriter: breadcrumb and geofence event writes
  geohash_utils.dart    — geohashP7 helper
  dwell_cooldown.dart   — dwell milestone deduplication
  utils.dart            — shared utilities
  zbg_location.dart     — barrel export
```

## FlutterFlow integration

This package is designed to be used from a FlutterFlow project via custom code files. See the [`example/`](example/) folder for:
- `geo_bootstrap.dart` — the bootstrap orchestrator (singleton, copy into FlutterFlow custom code)
- `geoStartFromConfig.dart` — FlutterFlow custom action to start geolocation
- `geostop.dart` — FlutterFlow custom action to stop geolocation

## Backend

A Firebase Cloud Functions v2 HTTP endpoint (`zbgIngest`) receives GPS batches from FBG's native HTTP transport, runs a server-side zone state machine to compute ENTER/DWELL events across batch boundaries, and writes breadcrumbs and geofence events to Firestore. The Cloud Function source is maintained separately.

## Development branches

### `good-sensor/scheduled-continuous`

Experimental branch replacing motion-detection-based sampling with continuous time-based periodic sampling within a scheduled window. Key differences from `main`/`good-sensor/headless-heartbeat-watchdog`:

- **`disableStopDetection: true`** — FBG runs continuously; the device never transitions to the stationary state and motion detection is disabled.
- **FBG schedule** — `schedule: ['1-7 05:00-00:00']` with `scheduleUseAlarmManager: true` (Android). `startSchedule()` replaces `start()` so FBG automatically stops at midnight and restarts at 5am via AlarmManager.
- **Hardcoded sampling rates** — rates are not read from Firestore for this test:
  - Outside zones: 600 s / 20 m
  - Near zones: 300 s / 10 m
  - Inside zones: 180 s / 5 m
- **Immediate sync** — `autoSyncThreshold: 0`, `batchSync: false` for real-time testing visibility.
- **Headless geofence handler** — `geo_fcm_handler.dart` uses the same hardcoded rates so terminated-state geofence `setConfig` calls are consistent with the live engine.

**Side effect:** With `disableStopDetection: true`, `checkGeoConfigChange` in the SPARRC app will always return `deferred:is_moving` (because `state.isMoving` is always `true`). The config-hash check is effectively bypassed on this branch — which is fine for a pure test of the sampling behavior.

## Dependencies

- `flutter_background_geolocation: ^5.0.1`
- `collection: ^1.18.0`
