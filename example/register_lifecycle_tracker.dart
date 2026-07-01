// Modified copy of register_lifecycle_tracker.dart.
// This version does not write last_foreground_at / last_background_at to users/{uid}.
// It keeps per-session docs under users/{uid}/app_sessions/{timestamp}
// and maintains users/{uid}/app_sessions/last_session as the latest summary doc.

import 'index.dart'; // Imports other custom actions

import 'package:flutter/widgets.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '/custom_code/geo_bootstrap.dart';

// Singleton lifecycle observer - registered once, lives for the app's lifetime.
class _AppSessionTracker with WidgetsBindingObserver {
  _AppSessionTracker._();
  static final _AppSessionTracker instance = _AppSessionTracker._();

  bool _registered = false;
  // Guards against double-writing on initial launch: register() calls
  // _onForeground() explicitly AND the resumed event may also fire.
  bool _isInForeground = false;
  String? _currentSessionDocId;
  DateTime? _sessionStartTime;

  void register() {
    if (_registered) return;
    WidgetsBinding.instance.addObserver(this);
    _registered = true;
    _onForeground();
  }

  void _onForeground() {
    if (_isInForeground) return;
    _isInForeground = true;
    GeoBootstrap.instance.ensureListeners();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final now = DateTime.now();
    final docId = now.millisecondsSinceEpoch.toString();
    _currentSessionDocId = docId;
    _sessionStartTime = now;

    final db = FirebaseFirestore.instance;
    final sessions = db.collection('users/$uid/app_sessions');

    sessions.doc(docId).set({
      'foreground_start': FieldValue.serverTimestamp(),
    });

    sessions.doc('last_session').set(
      {
        'last_foreground_at': FieldValue.serverTimestamp(),
        'current_session_id': docId,
        'is_foreground': true,
      },
      SetOptions(merge: true),
    );
  }

  void _onBackground() {
    if (!_isInForeground) return;
    _isInForeground = false;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _currentSessionDocId = null;
      _sessionStartTime = null;
      return;
    }

    final sessionDocId = _currentSessionDocId;
    final sessionStart = _sessionStartTime;
    _currentSessionDocId = null;
    _sessionStartTime = null;

    final db = FirebaseFirestore.instance;
    final sessions = db.collection('users/$uid/app_sessions');

    final lastSessionUpdate = <String, dynamic>{
      'last_background_at': FieldValue.serverTimestamp(),
      'is_foreground': false,
    };

    if (sessionDocId != null && sessionStart != null) {
      final durationSeconds = DateTime.now().difference(sessionStart).inSeconds;

      sessions.doc(sessionDocId).set(
        {
          'foreground_stop': FieldValue.serverTimestamp(),
          'foreground_duration_seconds': durationSeconds,
        },
        SetOptions(merge: true),
      );

      lastSessionUpdate['last_session_id'] = sessionDocId;
      lastSessionUpdate['last_foreground_duration_seconds'] = durationSeconds;
    }

    sessions.doc('last_session').set(
      lastSessionUpdate,
      SetOptions(merge: true),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onForeground();
    } else if (state == AppLifecycleState.paused) {
      _onBackground();
    }
  }
}

Future<void> registerLifecycleTracker() async {
  _AppSessionTracker.instance.register();
}
