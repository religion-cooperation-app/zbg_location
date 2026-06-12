# Geo ChangePace Liberal Guards Plan

This plan replaces the earlier guard-heavy `changePace(true)` event-nudge
approach for the next reliability iteration. It focuses on making
connectivity/geofence/motion wake signals more effective on Android devices
that remain stationary too long after the user starts walking.

## Target Failure

- Device has been stationary longer than `stop_timeout_minutes`.
- User starts walking while leaving Wi-Fi or entering weak/no connectivity.
- FBG emits `connectivitychange connected=false`, heartbeat, or geofence events.
- FBG does not transition to moving mode until much later.
- Breadcrumbs show a tracking gap before FBG eventually emits `setPace` /
  `motionchange` and active GPS resumes.

## Core Decision

Treat `changePace(true)` as a best-effort reliability nudge. A redundant or
failed `changePace(true)` attempt is less harmful than missing the one event
that should have pushed FBG into moving mode.

For devices whose FBG log reports degraded motion-detection capability, such
as missing gyroscope support, do not rely only on Android activity recognition
or stationary geofence exit. Use a combination of liberal pace nudges,
scheduled `disableStopDetection`, and a heartbeat watchdog.

The new helper should remove most guards:

```text
do not require known usable provider state
do not require GPS/network provider availability
do not skip if providerState cannot be read
do not require app-side uid/region inside Android headless mode
do not use cooldown for connectivity loss, geofence, or motionchange moving
```

Keep only execution safety:

```text
read/log FBG state if available, but do not skip on it
try changePace(true)
wrap changePace(true) in try/catch
write explicit FBG Logger markers for attempt/skipped/success/error
```

## Android Headless Helper

The Android headless handler must not use `GeoBootstrap` or `TsbgEngine`
singletons. It should call native FBG APIs directly.

```dart
Future<void> forceHeadlessMovingPace({required String source}) async {
  await fbg.Logger.notice('SPARRC force_pace attempt source=$source');

  try {
    final state = await fbg.BackgroundGeolocation.state;
    await fbg.Logger.notice(
      'SPARRC force_pace state source=$source enabled=${state.enabled} '
      'isMoving=${state.isMoving}',
    );
  } catch (_) {
    await fbg.Logger.notice(
      'SPARRC force_pace state_unreadable source=$source',
    );
  }

  try {
    await fbg.BackgroundGeolocation.changePace(true);
    await fbg.Logger.notice('SPARRC force_pace call_returned source=$source');
  } catch (e) {
    await fbg.Logger.notice(
      'SPARRC force_pace error source=$source error=${e.runtimeType}',
    );
  }
}
```

## Event Rules

```text
connectivitychange:
  connected=false -> forceHeadlessMovingPace('headless_connectivity_disconnected')
  connected=true  -> sync/flush; no forced pace unless another signal exists

geofence:
  ENTER/DWELL/EXIT, including _near fences -> force pace
  no provider guard
  no cooldown

motionchange:
  location.isMoving == true -> force pace
  no provider guard

providerchange:
  if event itself indicates provider became usable -> force pace
  skip if event clearly says services disabled or permission denied/restricted
```

Every handled headless event should log entry before branching so logs can
distinguish "native FBG emitted event but Dart headless did not run" from
"Dart headless ran and decided not to call `changePace(true)`":

```text
SPARRC headless_event received name=<eventName>
```

## Foreground/Background App-Side Helper

For the normal app isolate inside `zbg_location`, keep minimal engine lifecycle
checks so the app does not call through before geo has ever been configured.

Allowed checks:

```text
runtime config exists and enabled
engine ready/started
FBG state readable and enabled, if available
```

Remove provider-known-usable and cooldown requirements for:

```text
connectivity loss
geofence
motionchange moving
```

## Required Device Log Markers

Add `fbg.Logger.notice(...)` lines so exported FBG logs show the full decision
path. The log should make these cases distinguishable:

```text
native FBG event happened but Dart handler did not run
Dart handler ran for the event
Dart handler chose not to force pace because event rules did not match
Dart handler attempted force pace
Dart handler read FBG state and saw enabled/isMoving values
Dart handler could not read state but tried anyway
Dart handler called changePace(true) and the call returned
Dart handler called changePace(true) and FBG threw an error
native FBG later emitted setPace / motionchange
```

Recommended marker format:

```text
SPARRC headless_event received name=<eventName>
SPARRC force_pace not_applicable source=<source> reason=<reason>
SPARRC force_pace attempt source=<source>
SPARRC force_pace state source=<source> enabled=<bool> isMoving=<bool>
SPARRC force_pace skipped source=<source> reason=<reason>
SPARRC force_pace state_unreadable source=<source>
SPARRC force_pace call_returned source=<source>
SPARRC force_pace error source=<source> error=<runtimeType>
```

Use `call_returned`, not `success`, because it only proves the Dart call did
not throw. The native FBG log must still be checked for `setPace` or
`motionchange` to prove the plugin actually transitioned into moving mode.

For app-side `zbg_location` listeners, write the same marker family into the
FBG logger in addition to Crashlytics. Crashlytics-only logs are not enough for
field debugging because they do not appear in the exported FBG device log.

## Degraded Motion Device Override

Some Android devices may lack sensors that FBG uses for high-quality motion
detection. The FBG device log may show warnings such as missing gyroscope and
degraded motion-detection performance. These devices should use a more reliable
configuration without forcing that battery cost onto all users.

Add diagnostics fields:

```text
motion_sensor_gyro_available: true|false|unknown
motion_detection_degraded: true|false|unknown
recommended_disable_stop_detection: true|false
motion_detection_degraded_reason: <string>
```

If direct sensor capability is not available from Dart/FBG APIs, start with a
manual or server-side device override based on field evidence:

```text
appConfig/runtime/deviceOverrides/{uid}
  disable_stop_detection_override: true
  reason: no_gyroscope_motion_detection_degraded
  active_hours_only: true
```

Merge config in the app before building `RuntimeConfig`:

```text
base appConfig/runtime
+ device-specific override
+ active study window check
= effective RuntimeConfig
```

Runtime config should include active geo schedule hours:

```text
platform.active_geo_schedule.enabled = true|false
platform.active_geo_schedule.timezone = "Indian/Mauritius"
platform.active_geo_schedule.windows = [
  { days: [1,2,3,4,5,6,7], start: "07:00", end: "22:00" }
]
```

These schedule hours are not only for degraded devices. They define the window
where high-reliability geo behavior is allowed when `disableStopDetection` is
effective for a device.

Important implementation detail:

```text
The runtime schedule must be clock-driven, not only config-listener-driven.
```

If the app only evaluates schedule hours when Firestore listeners fire, then a
device that receives config at `21:59` will stay in that effective config after
`22:00` until another config/override event, foreground refresh, or restart
occurs. Add a local schedule-boundary timer that reapplies effective runtime
config at the next start/end boundary.

Recommended behavior:

```text
default users:
  platform.disable_stop_detection = false

global reliability mode:
  platform.disable_stop_detection = true
  effective disableStopDetection = true only inside active_geo_schedule windows

degraded device during active study hours:
  effective disableStopDetection = true

degraded device outside active study hours:
  effective disableStopDetection = false
```

Do not use FBG's built-in scheduler only to toggle this field. Prefer the
existing runtime config listener path so `disableStopDetection` can be updated
live with `BackgroundGeolocation.setConfig(...)`.

FBG's built-in scheduler can start/stop broad tracking windows, but it does not
directly express "only toggle `disableStopDetection` while keeping the rest of
the existing runtime config/listeners/geofence setup intact." For this use case,
the recommended implementation is:

```text
runtime/override listener fires
-> rebuild effective RuntimeConfig
-> apply BackgroundGeolocation.setConfig(...)
-> compute next active_geo_schedule boundary
-> schedule a local Timer for that boundary
-> when Timer fires, rebuild effective RuntimeConfig from latest cached docs
-> apply BackgroundGeolocation.setConfig(...) again
-> schedule the next boundary Timer
```

The timer is app-process local. If the app process is killed, the next
foreground start or geo bootstrap reads current config and applies the correct
state. If precise terminated-state boundary enforcement is required later, add
an Android/iOS alarm/background-fetch layer, but keep the FBG runtime config
merge as the source of truth.

Effective config rule:

```text
disableStopDetectionRequested =
  runtime.platform.disable_stop_detection == true
  OR deviceOverride.disable_stop_detection_override == true
  OR diagnostics.recommended_disable_stop_detection == true

effectiveDisableStopDetection =
  disableStopDetectionRequested
  AND active_geo_schedule currently allows high-reliability tracking
```

If `active_geo_schedule.enabled == false`, then scheduling is disabled and the
requested `disableStopDetection` value applies directly.

When effective `disableStopDetection` is true within scheduled hours, geo should
stay in the high-reliability mode for that window. Outside scheduled hours,
return to normal stop-detection behavior to reduce battery cost.

## Foreground Runtime Config Refresh

Add a lightweight foreground refresh action so devices pick up overrides after
being backgrounded, killed, or opened after a schedule boundary. This should not
replace the existing `geoStartFromConfig` permission/start flow.

Recommended `GeoBootstrap` method:

```text
refreshRuntimeConfig():
  if geo is not running in this app process:
    return skipped:not_running
  read appConfig/runtime
  read appConfig/runtime/deviceOverrides/{uid}
  rebuild effective RuntimeConfig
  call _engine.setConfig(cfg)
  return success
```

Recommended FlutterFlow custom action:

```text
refreshGeoRuntimeConfig()
  -> GeoBootstrap.instance.refreshRuntimeConfig()
```

Call conditions:

```text
user is signed in
app is foregrounded / HomePage loaded
geo has already been started in this app process
```

The action itself should enforce the `isRunning` check, so it is safe to call
on HomePage load without extra permission prompts or stale-breadcrumb logic.

Expected behavior:

```text
override added while app is alive:
  Firestore listener applies it automatically

override added while app was killed/backgrounded:
  refreshGeoRuntimeConfig applies it on next foreground if geo is running

geo is not running:
  refreshGeoRuntimeConfig returns skipped:not_running
  existing checkPermissions / geoStartFromConfig flow remains responsible
```

Do not add another unconditional `geoStartFromConfig` call to the HomePage
`checkPermissions` block. That path is heavier: it registers handlers, attaches
listeners, starts FBG, synthesizes geofence state, and writes `geo_running`.
The refresh action is only a config reapply for an already-started engine.

## Heartbeat Watchdog

The FBG log showed heartbeat events firing during the walk-start gap. That
makes heartbeat a useful fallback when motion detection and geofence delivery
are delayed.

Do not force pace on every heartbeat. Use heartbeat as an evidence-based
watchdog:

```text
onHeartbeat:
  if watchdog is rate-limited, skip
  get current position with a bounded timeout
  compare current position with the last recorded breadcrumb
  if last breadcrumb is stale and distance moved is large enough:
    call changePace(true)
    log the watchdog decision to FBG Logger
```

Suggested thresholds for first test:

```text
watchdog_check_interval_s = 120-300
breadcrumb_stale_after_s = 120-180
moved_distance_threshold_m = 50-100
getCurrentPosition timeout_s = 15-20
```

Recommended action:

```dart
final loc = await fbg.BackgroundGeolocation.getCurrentPosition(
  samples: 1,
  persist: true,
  timeout: 20,
);

if (lastBreadcrumbIsStale && distanceFromLastBreadcrumb >= thresholdM) {
  await fbg.BackgroundGeolocation.changePace(true);
}
```

Using `persist: true` is intentional for reliability because it gives the
native HTTP/SQLite path a location record even before moving mode fully wakes.
The battery cost is why the watchdog must be rate-limited and movement/staleness
gated.

Required watchdog log markers:

```text
SPARRC watchdog heartbeat_check source=<source>
SPARRC watchdog skipped reason=rate_limited
SPARRC watchdog skipped reason=no_last_breadcrumb
SPARRC watchdog skipped reason=breadcrumb_fresh
SPARRC watchdog current_position lat=<lat> lng=<lng> accuracy=<m>
SPARRC watchdog moved distance_m=<m> stale_s=<s>
SPARRC watchdog force_pace source=heartbeat_watchdog
SPARRC watchdog error stage=<stage> error=<runtimeType>
```

## Notification Policy

Return the Android FBG foreground service notification to non-sticky behavior:

```dart
notification: fbg.Notification(
  sticky: false,
)
```

The reliability work in this plan should come from scheduled
`disableStopDetection`, liberal `changePace(true)` nudges, and the heartbeat
watchdog rather than forcing a sticky user-visible notification. Keep the
notification priority/text/icon otherwise aligned with the current app policy.

## Validation

For the next offline/walk test, inspect the exported FBG log around the walk
start time and verify:

```text
connectivitychange connected=false
SPARRC headless_event received name=connectivitychange
SPARRC force_pace attempt source=headless_connectivity_disconnected
SPARRC force_pace call_returned source=headless_connectivity_disconnected
native setPace or motionchange appears shortly after
breadcrumbs appear earlier than prior tests
```

If `connectivitychange connected=false` appears without a `SPARRC force_pace`
marker, the native event did not reach the Dart handler. If the marker appears
but no native `setPace` follows, then FBG accepted or ignored the call without
transitioning, and the next mitigation should focus on `disableStopDetection`
or more aggressive heartbeat/watchdog behavior.

For degraded-motion devices, also verify:

```text
diagnostics identify degraded motion capability or a device override
effective disableStopDetection=true during active study hours
heartbeat watchdog logs appear during stationary/walk-start gap
watchdog either skips with a clear reason or calls force pace
```
