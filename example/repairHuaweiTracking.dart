// example/repairHuaweiTracking.dart
// FlutterFlow custom action — copy into the FlutterFlow action named
// repairHuaweiTracking.
//
// Return type: String  ('ok' | 'restarted' | 'restart_failed' | 'skipped:…')
// Arguments: none
//
// Huawei self-repair ladder (laventure_huawei plan §8/§10/§12): inspect FBG
// state → restart if EMUI killed it → fresh persisted fix → sync →
// changePace(true). Idempotent and safe to call repeatedly.
//
// Wire it to:
//   - a "Restore tracking" button on a Huawei help/settings page;
//   - the landing page opened by the recovery notification (plan §11), so
//     the tap → foreground → repair sequence is explicit;
//   - anywhere an RA needs a one-tap fix during onboarding.
//
// The automatic call sites (app foreground, HPK/FCM push wake, boot) are
// already wired in register_lifecycle_tracker.dart, huaweiPushHandler.dart,
// and geo_fcm_handler.dart — this action is the manual/UI entry point.

import '/custom_code/geo_bootstrap.dart';

Future<String> repairHuaweiTracking() async {
  try {
    return await GeoBootstrap.instance.repairTracking(source: 'manual_action');
  } on StateError catch (e) {
    return e.message;
  } catch (e) {
    return 'geo:unknown_error:${e.runtimeType}';
  }
}
