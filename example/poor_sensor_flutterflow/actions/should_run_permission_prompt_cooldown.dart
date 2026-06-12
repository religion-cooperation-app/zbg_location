// FlutterFlow custom action: shouldRunPermissionPromptCooldown
//
// Return type: Boolean
// Args:
//   promptKey: String
//   cooldownMinutes: int
//
// Purpose:
//   Returns true only if this prompt/settings action has not run recently.
//   When it returns true, it also records the current time in local SQLite.
//
// Suggested cooldownMinutes:
//   60

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

Future<bool> shouldRunPermissionPromptCooldown(
  String promptKey,
  int cooldownMinutes,
) async {
  if (promptKey.trim().isEmpty) {
    return false;
  }

  // FlutterFlow web tests should not be blocked by native SQLite availability.
  // On web, allow the prompt path to proceed.
  if (kIsWeb) {
    return true;
  }

  // This action is intended for mobile permission/settings prompts.
  if (!Platform.isAndroid && !Platform.isIOS) {
    return true;
  }

  final cooldown = Duration(
    minutes: cooldownMinutes <= 0 ? 60 : cooldownMinutes,
  );
  final now = DateTime.now().toUtc();

  final dbPath = await getDatabasesPath();
  final db = await openDatabase(
    path.join(dbPath, 'sparrc_permission_prompt_cooldowns.db'),
    version: 1,
    onCreate: (database, version) async {
      await database.execute('''
        CREATE TABLE permission_prompt_cooldowns (
          prompt_key TEXT PRIMARY KEY,
          last_shown_utc_ms INTEGER NOT NULL
        )
      ''');
    },
    onOpen: (database) async {
      await database.execute('''
        CREATE TABLE IF NOT EXISTS permission_prompt_cooldowns (
          prompt_key TEXT PRIMARY KEY,
          last_shown_utc_ms INTEGER NOT NULL
        )
      ''');
    },
  );

  try {
    final rows = await db.query(
      'permission_prompt_cooldowns',
      columns: const ['last_shown_utc_ms'],
      where: 'prompt_key = ?',
      whereArgs: [promptKey],
      limit: 1,
    );

    if (rows.isNotEmpty) {
      final rawLastShown = rows.first['last_shown_utc_ms'];
      final lastShownMs =
          rawLastShown is int ? rawLastShown : int.tryParse('$rawLastShown');
      if (lastShownMs != null) {
        final lastShown = DateTime.fromMillisecondsSinceEpoch(
          lastShownMs,
          isUtc: true,
        );
        if (now.difference(lastShown) < cooldown) {
          return false;
        }
      }
    }

    await db.insert('permission_prompt_cooldowns', {
      'prompt_key': promptKey,
      'last_shown_utc_ms': now.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return true;
  } finally {
    await db.close();
  }
}
