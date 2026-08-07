// example/geo_store_fid_uid_mapping.dart
// FlutterFlow custom action — geoStoreFidUidMapping
//
// Writes a fid → uid mapping to Firestore so zbgIngest can attribute
// orphaned breadcrumbs (those arriving with no uid due to the broken-params
// failure mode) back to the correct user after the fact.
//
// Required pub dependency in FlutterFlow project:
//   firebase_app_installations: ^0.3.2
//
// When to call:
//   1. In the FlutterFlow auth flow, immediately after successful sign-in.
//   2. At the start of the geo start custom action (geoStartFromConfig),
//      before or after bootstrap — order does not matter.
//
// The action is idempotent (uses set with merge:true) so calling it multiple
// times per session is safe and free of side effects.

import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io' show Platform;

Future<void> geoStoreFidUidMapping() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || uid.isEmpty) return;

  final fid = await FirebaseInstallations.instance.getId();

  await FirebaseFirestore.instance
      .collection('device_installations')
      .doc(fid)
      .set({
    'fid': fid,
    'uid': uid,
    'updated_at': FieldValue.serverTimestamp(),
    'platform': Platform.isAndroid ? 'android' : 'ios',
  }, SetOptions(merge: true));
}
