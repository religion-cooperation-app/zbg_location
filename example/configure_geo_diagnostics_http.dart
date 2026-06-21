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

import '/custom_code/geo_diagnostics_http.dart';

Future<String> configureGeoDiagnosticsHttp(
  String regionId,
  String endpointUrl,
  String apiKey,
  int? fetchIntervalMinutes,
  int? heartbeatIntervalHours,
  int? dailySnapshotHours,
) async {
  try {
    await GeoDiagnosticsHttp.configure(
      regionId: regionId,
      endpointUrl: endpointUrl,
      apiKey: apiKey,
      fetchIntervalMinutes: fetchIntervalMinutes ?? 360,
      heartbeatIntervalHours: heartbeatIntervalHours ?? 6,
      dailySnapshotHours: dailySnapshotHours ?? 24,
    );
    return 'success';
  } catch (e) {
    return 'geo_diag_http_configure_failed:${e.runtimeType}';
  }
}

// Set your action name, define your arguments and return parameter,
// and then add the boilerplate code using the green button on the right!
