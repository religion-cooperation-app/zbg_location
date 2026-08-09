// lib/custom_code/huaweiPushHandler.dart
// Huawei Push Kit (HPK) wake/recovery channel — laventure_huawei plan §7–§11.
//
// HPK is the PRIMARY wake channel on Huawei devices (most lack Google Play
// Services, so FCM never arrives). The existing FCM geo_wakeup handler in
// geo_fcm_handler.dart stays as the secondary/fallback channel for Huawei
// devices that do have GMS.
//
// Push Kit is a wake/recovery channel only — it does not replace FBG, and
// the native SQLite → HTTP path remains the data path (plan §14).
//
// FlutterFlow pubspec dependencies required:
//   huawei_push: ^6.15.0+300
//   firebase_core / cloud_firestore / firebase_auth (already FlutterFlow deps)
//   firebase_app_installations: (already used by geo_store_fid_uid_mapping)
//
// App-level setup required (see HUAWEI_IMPLEMENTATION.md at repo root):
//   - AppGallery Connect project + agconnect-services.json in android/app/
//   - com.huawei.agconnect Gradle plugin
//   - Server-side HPK sender in the geoWakeupSweep Cloud Function reading
//     device_installations/{fid}.hpk_token (cadence: plan §9,
//     platform.huawei_push_location_interval_minutes)
//
// Wiring (call from app startup / after sign-in, e.g. alongside
// geoStoreFidUidMapping):
//   await huaweiInitPushKit();

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:huawei_push/huawei_push.dart';

import '/custom_code/geo_fcm_handler.dart'
    show huaweiHeadlessProfileActive, huaweiHeadlessRepair;

StreamSubscription<String>? _tokenSub;

/// Initialise Huawei Push Kit: register the background data-message handler,
/// obtain the HPK token, and store it alongside the FCM token in
/// device_installations/{fid} so the geoWakeupSweep Cloud Function can send
/// HPK-first, FCM-fallback (plan §7).
///
/// Idempotent — safe to call on every app open. No-ops on non-Android.
/// Safe on non-Huawei Android: getToken simply fails without HMS Core and we
/// swallow the error.
Future<void> huaweiInitPushKit() async {
  if (!Platform.isAndroid) return;

  try {
    // Background/terminated data-message entry point.
    await Push.registerBackgroundMessageHandler(huaweiPushBackgroundHandler);
  } catch (_) {
    // HMS Core unavailable (non-Huawei device) — nothing to do.
    return;
  }

  // Token arrives via stream after getToken() is requested (getToken itself
  // is fire-and-forget void; the result is delivered on getTokenStream).
  _tokenSub ??= Push.getTokenStream.listen(
    _storeHpkToken,
    onError: (Object _) {},
  );
  try {
    Push.getToken('');
  } catch (_) {}

  // Foreground data messages (app open, message arrives) — run the same
  // repair ladder; harmless while everything is healthy (plan §12 overlap).
  Push.onMessageReceivedStream.listen((RemoteMessage msg) {
    unawaited(_handleGeoWake(msg, source: 'hpk_foreground'));
  }, onError: (Object _) {});
}

/// Persist the HPK token next to the FCM token / FID→UID mapping used by
/// zbgIngest attribution, so the wakeup sender can target this device.
Future<void> _storeHpkToken(String token) async {
  if (token.isEmpty) return;
  try {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final fid = await FirebaseInstallations.instance.getId();
    if (fid.isEmpty) return;
    await FirebaseFirestore.instance
        .collection('device_installations')
        .doc(fid)
        .set({
      'hpk_token': token,
      'hpk_token_updated_at': FieldValue.serverTimestamp(),
      if (uid != null && uid.isNotEmpty) 'uid': uid,
      'platform': 'android',
      'oem_channel': 'hpk',
    }, SetOptions(merge: true));
  } catch (_) {
    // Token storage is retried on next app open via huaweiInitPushKit().
  }
}

/// Background/terminated HPK data-message handler (plan §8).
/// Top-level + entry-point so release builds keep it for the background
/// isolate Huawei spawns on data-message delivery.
@pragma('vm:entry-point')
Future<void> huaweiPushBackgroundHandler(RemoteMessage message) async {
  await _handleGeoWake(message, source: 'hpk_geo_wakeup');
}

/// Plan §8 ladder on every delivered Huawei geo wake:
///   inspect FBG state
///   → enabled:   fresh persisted fix (maximumAge:0) + sync + changePace(true)
///   → disabled:  attempt start(); on success same fix/sync/pace;
///                on failure → visible recovery notification (plan §11)
/// All of that lives in huaweiHeadlessRepair (shared with the FCM fallback),
/// which also records the outcome to huawei_recovery_events (plan §10).
Future<void> _handleGeoWake(RemoteMessage message,
    {required String source}) async {
  final data = message.dataOfMap ?? const <String, String>{};
  if (data['type'] != 'geo_wakeup') return;
  if (!await huaweiHeadlessProfileActive()) return;

  final outcome = await huaweiHeadlessRepair(
    source: source,
    wakeId: data['wake_id'],
  );
  if (outcome == 'restart_failed') {
    await _showRecoveryNotification();
  }
}

/// Plan §11: visible tap-to-repair fallback. User interaction gives Android a
/// far stronger context for starting a foreground location service than an
/// unattended background handler. Tapping opens SPARRC → the app-foreground
/// self-repair in register_lifecycle_tracker.dart (plan §12) runs
/// start() → changePace(true) → fresh fix → sync.
Future<void> _showRecoveryNotification() async {
  try {
    await Push.localNotification({
      HMSLocalNotificationAttr.TITLE: 'SPARRC location tracking needs attention',
      HMSLocalNotificationAttr.MESSAGE: 'Tap to restore study location tracking.',
      HMSLocalNotificationAttr.TAG: 'sparrc_geo_recovery',
      HMSLocalNotificationAttr.AUTO_CANCEL: true,
    });
  } catch (_) {
    // Notification API unavailable — the next HPK wake, app open, or boot
    // will retry the repair ladder.
  }
}
