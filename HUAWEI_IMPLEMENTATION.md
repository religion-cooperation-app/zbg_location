# Huawei Reliability Profile — Setup & Operations Guide (`laventure_huawei`)

Implements `Huawei_Background_Location_Implementation_Plan_v3.md`. This
document covers everything the code cannot do by itself: HMS location
licensing, AppGallery/Push Kit console setup, the server-side wake sender,
participant device configuration, and release verification.

## What is already implemented in this branch

| Plan item | Where |
|---|---|
| 1. Huawei detection + `platform.huawei_*` runtime flags | `TsbgEngine.detectHuaweiDevice()` / `isHuaweiReliabilityMode`; `RuntimeConfig` (api.dart); parsed in `geo_bootstrap.dart` |
| 2. Continuous `start()` + `changePace(true)` (no 05:00 schedule) | `TsbgEngine.setConfig()` (schedule omitted) + `start()` |
| 3. Sticky low-priority foreground notification | `TsbgEngine.setConfig()` notification block |
| 4. `stopTimeout` from runtime config (was hardcoded 30) | `TsbgEngine.setConfig()` |
| 5. No significant-change-only mode on Huawei | `TsbgEngine._applyMode()` outside case |
| 6. `changePace(true)` at activation/recovery points + geofence ENTER/EXIT + connectivity triggers (foreground AND headless) | `TsbgEngine.huaweiForcePace()`; listeners in `_attachListeners()`; `geoFbgHeadlessTask` branches in `geo_fcm_handler.dart` |
| 7. HPK primary / FCM fallback wake channels | `huaweiPushHandler.dart` (HPK); `geoFirebaseMessagingBackgroundHandler` Android path (FCM fallback) |
| 8. Fresh persisted fix on every geo wake | `huaweiHeadlessRepair()` in `geo_fcm_handler.dart` (`maximumAge:0, persist:true` → `sync()` → `changePace(true)`) |
| 10. Restart-on-push + outcome recording | `huaweiHeadlessRepair()` → `huawei_recovery_events` collection |
| 11. Visible tap-to-repair notification | `_showRecoveryNotification()` in `huaweiPushHandler.dart`; tap → app open → §12 repair |
| 12. App-open self-repair | `register_lifecycle_tracker.dart` `_onForeground()` → `GeoBootstrap.repairTracking()` |
| 13. Boot recovery | `geoFbgHeadlessTask` `boot` branch; `startOnBoot`/`stopOnTerminate`/`enableHeadless` retained |
| 14. Native persistence/HTTP preserved | unchanged; repair uses `persist:true` |
| §12/§11 manual entry point | `repairHuaweiTracking.dart` custom action |

Remaining: everything below.

---

## 1. HMS Location Kit — REQUIRED reading before testing

**Most post-2019 Huawei devices have no Google Play Services (GMS).** FBG's
Android implementation rides on GMS for two critical things:

- **FusedLocationProviderClient** — location acquisition;
- **ActivityRecognition** — the motion API that transitions FBG
  stationary → moving.

Without GMS, motion detection is dead (device stays `still` forever) and
location quality degrades — this alone can produce the observed pattern of
"breadcrumb at explicit activation, silence in between." The profile's
`changePace(true)`-everywhere design works around dead motion detection, but
location acquisition itself still needs a working provider.

**Transistorsoft sells official Huawei HMS support** (native library ≥ 4.10.0,
included in the `flutter_background_geolocation 5.0.1` this branch uses):

1. Purchase the separate Huawei license key:
   <https://shop.transistorsoft.com/collections/frontpage/products/huawei-background-geolocation>
2. Add the key to the app's `AndroidManifest.xml` alongside the existing
   Transistorsoft license (per the product's install instructions).
3. The HMS Location SDK version is controlled by the `hmsLocationVersion`
   Gradle ext (defaults to `6.12.0.300` in the plugin's `build.gradle`).
   Override in the app's `android/build.gradle` `ext {}` block only if AGC
   flags an outdated dependency.

With the HMS license in place, FBG uses HMS Location Kit + HMS
ActivityIdentification on GMS-less devices. Without it, expect degraded or
absent tracking on those devices no matter what this profile does — budget
for the license before interpreting field results.

Bonus: FBG's `DeviceSettings` API can deep-link Huawei's vendor settings
screens (battery / app-launch) from inside the app — useful for §5 onboarding
(`DeviceSettings.showPowerManager()` / `showIgnoreBatteryOptimizations()`).

## 2. AppGallery Connect + Push Kit setup

1. Create a project + app in [AppGallery Connect](https://developer.huawei.com/consumer/en/service/josp/agc/index.html)
   with the SPARRC `applicationId`.
2. Enable **Push Kit** (Project settings → Manage APIs).
3. Add the app's **SHA-256 signing certificate fingerprint** (release keystore).
4. Download `agconnect-services.json` → place in `android/app/`.
5. App `android/build.gradle` (project level):
   ```gradle
   buildscript {
     repositories { maven { url 'https://developer.huawei.com/repo/' } }
     dependencies { classpath 'com.huawei.agconnect:agcp:1.9.1.301' }
   }
   allprojects { repositories { maven { url 'https://developer.huawei.com/repo/' } } }
   ```
6. App `android/app/build.gradle`: `apply plugin: 'com.huawei.agconnect'`
7. Pubspec: `huawei_push: ^6.15.0+300`
8. Call `huaweiInitPushKit()` at app startup (alongside
   `geoStoreFidUidMapping` in the sign-in flow). It registers the background
   handler, obtains the HPK token, and stores it in
   `device_installations/{fid}.hpk_token`.

## 3. Server-side wake sender (geoWakeupSweep extension)

Current `geoWakeupSweep` sends FCM data messages. Extend it:

1. **Token selection:** for each target device read
   `device_installations/{fid}` — if `hpk_token` present, send HPK first;
   fall back to FCM token if the HPK send errors or no `hpk_token` exists
   (plan §7).
2. **HPK send:** OAuth2 client-credentials against
   `https://oauth-login.cloud.huawei.com/oauth2/v3/token` using the AGC app's
   Client ID/Secret (store in Cloud Function secrets), then POST to
   `https://push-api.cloud.huawei.com/v1/{appId}/messages:send`:
   ```json
   {
     "message": {
       "data": "{\"type\":\"geo_wakeup\"}",
       "android": { "urgency": "HIGH" },
       "token": ["<hpk_token>"]
     }
   }
   ```
   Data-only message — the Dart background handler (`huaweiPushBackgroundHandler`)
   receives it; no notification is shown by the OS.
3. **Cadence (plan §9):** during the active tracking window, send every
   `platform.huawei_push_location_interval_minutes` (default 7; start in the
   5–10 min band). Do NOT assume delivery: EMUI throttles data messages to
   force-stopped/restricted apps. Compare `huawei_recovery_events` rows
   against sends to measure real delivery.
4. Retain the existing stale-location watchdog/retry logic unchanged.

## 4. Runtime config flags (appConfig/runtime → `platform` map)

| Field | Default | Meaning |
|---|---|---|
| `huawei_reliability_mode` | `false` | Master switch. Inert on non-Huawei hardware regardless. |
| `huawei_keep_fbg_continuous` | `true` | `start()` 24/7 instead of `startSchedule()` |
| `huawei_disable_significant_changes` | `true` | Never sig-change-only outside |
| `huawei_force_moving_on_recovery` | `true` | `changePace(true)` at recovery points |
| `huawei_push_recovery_enabled` | `true` | Headless push repair ladder active |
| `huawei_push_location_interval_minutes` | `7` | Advisory cadence for the sender |

Rollout: set `huawei_reliability_mode: true` remotely once a Huawei test
device is enrolled; kill it the same way. No APK ship needed.

**Overnight note (plan §2):** continuous mode collects 00:00–05:00 samples
the old schedule did not. Client-side discarding would fight the native
persistence path (§14) — if overnight data must be excluded, filter
server-side in zbgIngest/analysis by local hour.

## 5. Participant device configuration (plan §15)

RA checklist per Huawei device (Settings paths vary by EMUI version):

**App launch:** Settings → Apps → SPARRC → App launch → turn OFF "Manage
automatically" → enable all three: **Auto-launch**, **Secondary launch**,
**Run in background**.

**Battery:** Settings → Battery → App launch/Battery optimization → SPARRC
→ **Don't optimize**; disable Power Saving / Ultra Power Saving modes for the
study period; enable **"Stay connected while sleeping"** (Settings → Battery →
More battery settings); open Recents → pull SPARRC card down to **lock** it.

In-app: `DeviceSettings.showPowerManager()` (FBG) deep-links the vendor
screen — wire it into the Huawei onboarding page next to these instructions.

These settings are the strongest non-root lever against EMUI killing; the
code profile is second place.

## 6. Merged manifest verification (plan §16)

Build a release bundle, then inspect the **merged** manifest
(`android/app/build/intermediates/merged_manifests/release/AndroidManifest.xml`
or Android Studio's *Merged Manifest* tab). Verify:

```
ACCESS_FINE_LOCATION            ACCESS_COARSE_LOCATION
ACCESS_BACKGROUND_LOCATION      FOREGROUND_SERVICE
FOREGROUND_SERVICE_LOCATION     RECEIVE_BOOT_COMPLETED
ACTIVITY_RECOGNITION            WAKE_LOCK
ACCESS_NETWORK_STATE
```

plus FBG's service declared with `android:foregroundServiceType="location"`
and its boot receiver. Do not hand-duplicate Transistorsoft declarations —
the plugin injects them; verify presence only.

## 7. Acceptance criteria (from the plan)

On a Huawei test device: FBG stays enabled across day + overnight; startup
calls `changePace(true)`; swipe-away doesn't stop native tracking; reboot
restores tracking; every delivered wake attempts a fresh persisted fix
(check `huawei_recovery_events` + breadcrumbs); disabled FBG triggers restart
attempt; failed restart shows the recovery notification; tapping it restores
tracking; app open repairs stale/disabled FBG; SQLite retains unsent fixes
offline and syncs on recovery; the whole profile turns off remotely via
`huawei_reliability_mode: false`.

**Limitation (plan):** nothing recovers from a true force-stop until the user
interacts. The ladder is: prevent kill → survive Flutter death → push
recovery → FBG restart → visible user-assisted recovery.
