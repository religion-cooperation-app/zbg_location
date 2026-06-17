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

// FlutterFlow custom action: geoRefreshGeofences
//
// Return type: String
// Arguments:
//   regionId (String) — the region whose geofences to refresh
//
// Purpose:
//   Lightweight foreground geofence refresh. Fetches the current
//   regions/{regionId}/geofences collection from Firestore and diffs it
//   against what FBG currently has registered, adding or removing only
//   what changed. Does NOT restart listeners, re-init the engine, or
//   re-write any user state — safe to call on any foreground event.
//
//   Use this anywhere you want an explicit geofence sync outside of the
//   automatic triggers (WidgetsBindingObserver in GeoBootstrap handles
//   app-resume automatically; this action is for additional call sites).
//
// Required existing dependencies:
//   zbg_location (path dep via GeoBootstrap)
//   flutter_background_geolocation
//   firebase_crashlytics

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import '/custom_code/geo_bootstrap.dart';

Future<String> geoRefreshGeofences(String? regionId) async {
  if (kIsWeb) return 'not_applicable:web';

  if (regionId == null || regionId.isEmpty) return 'skipped:no_region_id';

  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || uid.isEmpty) return 'skipped:no_user';

  try {
    await GeoBootstrap.instance.refreshGeofencesFromFirestore(regionId);
    return 'success:regionId=$regionId';
  } catch (e, st) {
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      fatal: false,
      reason: 'geo_refresh_geofences_action_failed',
    );
    return 'error:${e.runtimeType}';
  }
}

// Set your action name, define your arguments and return parameter,
// and then add the boilerplate code using the green button on the right!
