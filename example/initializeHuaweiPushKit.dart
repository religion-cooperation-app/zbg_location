// example/initializeHuaweiPushKit.dart
// FlutterFlow custom action — copy into your FlutterFlow project under
// custom_code/actions/initializeHuaweiPushKit.dart
//
// Arguments: none
// Return type: Future<void>
//
// Call once after Firebase initialization and user sign-in, alongside
// geoStoreFidUidMapping. It registers Huawei Push Kit background/foreground
// handlers, requests the HPK token, and stores token updates against the
// device installation. It is safe to call again on later app opens.

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

import '/custom_code/huaweiPushHandler.dart';

Future<void> initializeHuaweiPushKit() async {
  await huaweiInitPushKit();
}
