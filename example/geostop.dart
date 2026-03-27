// example/geostop.dart
// FlutterFlow custom action — copy into your FlutterFlow project under
// custom_code/actions/geostop.dart
//
// Stops geolocation and writes geo_running: false + geo_session_stopped to
// the user document. Safe to call even if geo was never started — the write
// is skipped if no session is active (_uid null guard in GeoBootstrap.stop()).

// Automatic FlutterFlow imports
import '/backend/backend.dart';
import '/backend/schema/structs/index.dart';
import '/backend/schema/enums/enums.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/actions/index.dart'; // Imports other custom actions
import '/flutter_flow/custom_functions.dart'; // Imports custom functions
import 'package:flutter/material.dart';
// Begin custom action code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import '/custom_code/geo_bootstrap.dart';

Future geostop() async {
  await GeoBootstrap.instance.stop();
}
