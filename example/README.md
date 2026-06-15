# FlutterFlow Integration Layer

These files are the glue between the `zbg_location` package and a FlutterFlow project. They are not part of the package itself — they live in the FlutterFlow project as custom code files and call into the package via the `GeoBootstrap` singleton.

## Files

### `geo_bootstrap.dart`
The bootstrap orchestrator. A singleton (`GeoBootstrap.instance`) that:
- Reads study configuration (`appConfig/runtime`) and geofence definitions (`regions/{regionId}/geofences`) from Firestore at session start, with live listeners that propagate updates without an app restart
- Configures and starts `TsbgEngine` (the FBG wrapper in the package)
- Subscribes to location and geofence event streams and writes breadcrumbs and geofence events to Firestore
- Registers background wakeup handlers (FCM silent push, iOS background fetch, Android FBG headless task)
- Broadcasts zone state changes via `onZoneChange` for consumption by the BLE proximity system
- Writes `geo_running`, `geo_session_started`, and `geo_session_stopped` to the user document for server-side monitoring

Copy to: `lib/custom_code/geo_bootstrap.dart` in your FlutterFlow project.

### `geo_fcm_handler.dart`
FCM background message handler, iOS background-fetch headless task, and Android FBG headless task. It handles terminated-state FBG events, headless heartbeat watchdog diagnostics, near-zone forcewake, location candidate persistence, and Android geofence event writes.

Copy to: `lib/custom_code/geo_fcm_handler.dart` in your FlutterFlow project.

### `geoStartFromConfig.dart`
FlutterFlow custom action that calls `GeoBootstrap.instance.startFromFirestore(regionId)`. Returns `'success'` or an error string. Call on sign-in and conditionally on the homepage (gated by `isBreadcrumbStale`).

Copy to: `lib/custom_code/actions/geoStartFromConfig.dart`.

### `geostop.dart`
FlutterFlow custom action that calls `GeoBootstrap.instance.stop()`. Returns `'success'` or an error string. Wrapped in try-catch so failures do not block subsequent actions in the FlutterFlow action sequence. Call on sign-out.

Copy to: `lib/custom_code/actions/geostop.dart`.

### `zbgIngest.js`
The Firebase Cloud Functions v2 HTTP endpoint that receives GPS fix batches from FBG's native HTTP transport. This is the server-side counterpart to `TsbgEngine` — it runs a zone state machine that persists zone entry timestamps and dwell state across HTTP batch boundaries (including terminated-state wakeups where each POST is a single location), computes ENTER/DWELL/EXIT events from raw GPS coordinates, and writes breadcrumbs and geofence events to Firestore. It also handles native geofence events posted by FBG in background/terminated state.

Key behaviours:
- **Dual gate**: breadcrumbs are gated by `breadcrumbs.enabled` + region allowlist; geofence events bypass the breadcrumb switch (geofence-only gate) so critical events are never silenced
- **Zone state machine**: seeds `prevZoneId`, `enteredAt`, and `lastFiredMilestoneS` from the user doc on each invocation, writes them back at the end — surviving across batch boundaries
- **EXIT hysteresis buffer** (30 m): prevents flickering EXIT when GPS is near the fence edge
- **Geofence-only mode**: suppresses outside-zone breadcrumbs when `mode === 'geofence_only'`
- **Fence geometry cache**: loads from `regions/{regionId}/meta/geofenceIndex` with a 5-minute in-process cache

In production this function lives in `functions/index.js` alongside the rest of the project's Cloud Functions. It is extracted here for review.

## Additional custom files (not included here)

The following files are also required in the FlutterFlow project but are more project-specific:

- `zbg_firestore_adapter.dart` — `WriteFn` adapter that bridges `FirestoreWriter` to the Firebase SDK available in FlutterFlow
- `geo_diagnostics_http.dart` — diagnostics helper used by the headless handler
- `isBreadcrumbStale.dart` — custom action that reads `last_breadcrumb_ts` from the user document to gate homepage restarts
- `geoFlushBuffer.dart` — custom action that calls `GeoBootstrap.instance.flushBuffer()` on homepage visits

## Firestore data model

The integration layer expects the following Firestore structure:

```
appConfig/runtime              — sampling rates, distance filters, dwell thresholds
appConfig_regions/{regionId}   — region existence check
regions/{regionId}/geofences   — geofence definitions (circle: center.lat, center.lng, radius_m)
users/{uid}                    — user document (geo_running, geo_session_started, geo_session_stopped, last_breadcrumb_ts)
regions/{regionId}/breadcrumbs — GPS fix documents written by zbgIngest and Dart path
geofence_events                — ENTER/EXIT/DWELL event documents
```
