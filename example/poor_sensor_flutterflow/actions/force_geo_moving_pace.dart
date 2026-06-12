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

import '/custom_code/geo_bootstrap.dart';

Future<String> forceGeoMovingPace() async {
  return GeoBootstrap.instance.forceMovingPace(source: 'foreground_resume');
}

// Set your action name, define your arguments and return parameter,
// and then add the boilerplate code using the green button on the right!
