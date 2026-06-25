// example/geo_store_fid_uid_mapping.dart
// FlutterFlow custom action — geoStoreFidUidMapping
//
// Writes a fid → uid → regionId mapping to Firestore so zbgIngest can
// attribute orphaned breadcrumbs (those arriving with no uid due to the
// broken-params failure mode) back to the correct user and run the full
// zone state machine on them.
//
// Required pub dependency in FlutterFlow project:
//   firebase_installations: ^0.3.0
//
// When to call:
//   - Immediately after sign-up succeeds (auth flow).
//   - Immediately after sign-in succeeds (auth flow).
//   regionId must be available in app state at both call sites.
//
// The action is idempotent (uses set with merge:true) so calling it on
// both sign-up and sign-in is safe and produces no side effects.

import 'package:firebase_installations/firebase_installations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io' show Platform;

Future<void> geoStoreFidUidMapping({required String regionId}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || uid.isEmpty) return;
  if (regionId.isEmpty) return;

  final fid = await FirebaseInstallations.instance.getId();

  await FirebaseFirestore.instance
      .collection('device_installations')
      .doc(fid)
      .set({
    'fid': fid,
    'uid': uid,
    'regionId': regionId,
    'updated_at': FieldValue.serverTimestamp(),
    'platform': Platform.isAndroid ? 'android' : 'ios',
  }, SetOptions(merge: true));
}
