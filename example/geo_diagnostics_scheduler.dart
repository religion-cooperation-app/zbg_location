// lib/custom_code/geo_diagnostics_scheduler.dart
//
// Conservative Android scheduled diagnostics using background_fetch.
//
// This does not request GPS, does not call FBG sync, and does not alter FBG
// sampling. It only reads current permission/provider/power state and sends a
// compact HTTP diagnostic snapshot if state changed or the daily window is due.

import 'dart:io' show Platform;

import 'package:background_fetch/background_fetch.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import '/custom_code/geo_diagnostics_http.dart';

const String geoDiagnosticsScheduledTaskId = 'sparrc_geo_diagnostics_audit';

class GeoDiagnosticsScheduler {
  GeoDiagnosticsScheduler._();

  static bool _configured = false;

  /// Android-only scheduled audit.
  ///
  /// Must be called AFTER GeoDiagnosticsHttp.configure() has stored
  /// uid/region/endpoint/apiKey/intervals in SQLite, so the fetch interval
  /// is sourced from the same Firestore-backed config.
  static Future<String> configure() async {
    if (_configured) return 'ok:already_configured';
    if (!Platform.isAndroid) return 'unsupported_platform';
    _configured = true;

    try {
      final fetchIntervalMinutes =
          await GeoDiagnosticsHttp.readFetchIntervalMinutes();

      await BackgroundFetch.configure(
        BackgroundFetchConfig(
          minimumFetchInterval: fetchIntervalMinutes,
          stopOnTerminate: false,
          startOnBoot: true,
          enableHeadless: true,
          requiredNetworkType: NetworkType.ANY,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
          requiresStorageNotLow: false,
          forceAlarmManager: false,
        ),
        (String taskId) async {
          try {
            await GeoDiagnosticsHttp.recordScheduledSnapshot(
              source: 'background_fetch',
            );
            await GeoDiagnosticsHttp.flushPending(
              limit: 10,
              deliverySource: 'background_fetch_flush',
            );
          } finally {
            BackgroundFetch.finish(taskId);
          }
        },
        (String taskId) async {
          BackgroundFetch.finish(taskId);
        },
      );

      await BackgroundFetch.registerHeadlessTask(
        geoDiagnosticsBackgroundFetchHeadlessTask,
      );
      await BackgroundFetch.start();

      fbg.BackgroundGeolocation.onHeartbeat((fbg.HeartbeatEvent event) async {
        await GeoDiagnosticsHttp.recordHeartbeatSnapshot(
          source: 'fbg_heartbeat',
        );
      });

      return 'ok';
    } catch (e) {
      return 'error:${e.toString()}';
    }
  }
}

@pragma('vm:entry-point')
void geoDiagnosticsBackgroundFetchHeadlessTask(HeadlessEvent task) async {
  final taskId = task.taskId;

  if (task.timeout) {
    BackgroundFetch.finish(taskId);
    return;
  }

  try {
    await GeoDiagnosticsHttp.recordScheduledSnapshot(
      source: 'background_fetch_headless',
    );
    await GeoDiagnosticsHttp.flushPending(
      limit: 10,
      deliverySource: 'background_fetch_headless_flush',
    );
  } finally {
    BackgroundFetch.finish(taskId);
  }
}
