// Automatic FlutterFlow imports
import '/backend/backend.dart';
import '/backend/schema/structs/index.dart';
import '/backend/schema/enums/enums.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'index.dart'; // Imports other custom actions
import '/flutter_flow/custom_functions.dart'; // Imports custom functions
import 'package:flutter/material.dart';
// Begin custom action code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

Future<String> emailFbgDeviceLog(
  String email,
  int? hoursBack,
  int? limit,
) async {
  if (kIsWeb) return 'not_applicable';
  if (email.trim().isEmpty) return 'error:missing_email';

  try {
    final safeHoursBack = hoursBack == null || hoursBack <= 0 ? 6 : hoursBack;
    final safeLimit = limit == null || limit <= 0 ? 5000 : limit;
    final end = DateTime.now();
    final start = end.subtract(Duration(hours: safeHoursBack));
    final success = await fbg.Logger.emailLog(
      email.trim(),
      fbg.SQLQuery(
        start: start,
        end: end,
        order: fbg.SQLQuery.ORDER_DESC,
        limit: safeLimit,
      ),
    );
    return success ? 'success' : 'failed_to_open_email_log';
  } catch (e) {
    return 'error:${e.runtimeType}';
  }
}
