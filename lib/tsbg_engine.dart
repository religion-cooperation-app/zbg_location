// lib/tsbg_engine.dart
import 'dart:async';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;
import 'api.dart';

class TsbgEngine implements LocationEngine {
  final _locCtl = StreamController<LocationSample>.broadcast();
  final _fenceCtl = StreamController<GeofenceEvent>.broadcast();
  bool _ready = false;

  @override
  Stream<LocationSample> onLocation() => _locCtl.stream;

  @override
  Stream<GeofenceEvent> onGeofence() => _fenceCtl.stream;

  @override
  Future<void> setConfig(RuntimeConfig cfg) async {
    // Map RuntimeConfig -> FBG Config
    await fbg.BackgroundGeolocation.ready(
      fbg.Config(
        startOnBoot: cfg.startOnBoot,
        stopOnTerminate: cfg.stopOnTerminate,
        debug:
            false, // set true during device debugging if you want sounds/logs
        desiredAccuracy: fbg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: _distanceFilterFor(cfg.rateOutsideS)
            .toDouble(), // <- cast to double
        heartbeatInterval: _heartbeatFor(cfg.rateOutsideS),
        disableElasticity: true,
        stopTimeout: 5, // minutes of inactivity before idling
        useSignificantChangesOnly: cfg.useSignificantChangeWhenOutside,
      ),
    );

    if (!_ready) {
      _attachListeners();
      _ready = true;
    }
  }

  @override
  Future<void> start() async {
    await fbg.BackgroundGeolocation.start();
  }

  @override
  Future<void> stop() async {
    await fbg.BackgroundGeolocation.stop();
  }

  @override
  Future<void> addGeofences(List<GeofenceDef> defs) async {
    for (final d in defs) {
      if (d.type == "circle") {
        await fbg.BackgroundGeolocation.addGeofence(
          fbg.Geofence(
            identifier: d.id,
            latitude: d.lat!,
            longitude: d.lng!,
            radius: (d.radiusM ?? 50).toDouble(), // <- double, not int
            notifyOnEntry: true,
            notifyOnExit: true,
            notifyOnDwell: true,
            loiteringDelay: 1000, // ms; tune vs dwellRequiredS
          ),
        );
      } else {
        // Polygon geofences require the polygon add-on for production builds.
        // In DEBUG you can experiment; otherwise skip and do server-side polygon checks.
        // Example when licensed:
        // await fbg.BackgroundGeolocation.addPolygon(
        //   fbg.PolygonGeofence(
        //     identifier: d.id,
        //     coordinates: d.polygon!
        //         .map((p) => fbg.Coordinate(p[0], p[1]))
        //         .toList(),
        //     notifyOnEntry: true,
        //     notifyOnExit: true,
        //     notifyOnDwell: true,
        //     loiteringDelay: 1000,
        //   ),
        // );
      }
    }
  }

  @override
  Future<void> removeGeofence(String id) async {
    await fbg.BackgroundGeolocation.removeGeofence(id);
  }

  @override
  Future<void> setSamplingMode(SamplingMode mode) async {
    final distance = switch (mode) {
      SamplingMode.outside => 100,
      SamplingMode.near => 30,
      SamplingMode.inside => 10,
    };
    final heartbeat = switch (mode) {
      SamplingMode.outside => 300,
      SamplingMode.near => 60,
      SamplingMode.inside => 30,
    };
    await fbg.BackgroundGeolocation.setConfig(
      fbg.Config(
        distanceFilter: distance.toDouble(), // <- cast to double
        heartbeatInterval: heartbeat,
      ),
    );
  }

  void _attachListeners() {
    fbg.BackgroundGeolocation.onLocation((fbg.Location l) {
      final c = l.coords;
      _locCtl.add(LocationSample(
        c.latitude,
        c.longitude,
        c.accuracy, // <- accuracy is non-nullable in this SDK; remove ?? 0
        DateTime.now().toUtc(),
      ));
    });

    fbg.BackgroundGeolocation.onGeofence((fbg.GeofenceEvent e) {
      final t = switch (e.action) {
        'ENTER' => GeofenceEventType.enter,
        'EXIT' => GeofenceEventType.exit,
        'DWELL' => GeofenceEventType.dwell,
        _ => GeofenceEventType.enter,
      };
      _fenceCtl.add(GeofenceEvent(e.identifier, t, DateTime.now().toUtc()));
    });
  }

  int _distanceFilterFor(int rateSeconds) {
    if (rateSeconds >= 300) return 100; // outside
    if (rateSeconds >= 60) return 30; // near
    return 10; // inside
  }

  int _heartbeatFor(int rateSeconds) {
    if (rateSeconds >= 300) return 300;
    if (rateSeconds >= 60) return 60;
    return 30;
  }
}
