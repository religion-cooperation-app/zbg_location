// example/geoStartFromConfig.dart
// FlutterFlow custom action — copy into your FlutterFlow project under
// custom_code/actions/geoStartFromConfig.dart
//
// Starts geolocation for the signed-in user in the given region.
// Returns 'success' on success, or an error message string on failure.
// Call this on sign-in and conditionally on homepage (gated by isBreadcrumbStale).

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

Future<String> geoStartFromConfig(String regionId) async {
  try {
    await GeoBootstrap.instance.startFromFirestore(regionId);
    return 'success';
  } on StateError catch (e) {
    return e.message;
  } catch (e) {
    return e.toString();
  }
}
