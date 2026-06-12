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

Future<String> enableFbgVerboseLogging(
  int? logMaxDays,
  bool? debugSounds,
) async {
  if (kIsWeb) return 'not_applicable';

  try {
    await fbg.BackgroundGeolocation.setConfig(
      fbg.Config(
        logger: fbg.LoggerConfig(
          debug: debugSounds ?? false,
          logLevel: fbg.LogLevel.verbose,
          logMaxDays: logMaxDays ?? 3,
        ),
      ),
    );
    await fbg.Logger.notice('SPARRC enabled FBG verbose logging');
    return 'success';
  } catch (e) {
    return 'error:${e.runtimeType}';
  }
}
