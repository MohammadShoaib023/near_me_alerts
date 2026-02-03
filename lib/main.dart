import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:permission_handler/permission_handler.dart';

const double defaultRadiusMeters = 200;
const String _geofencePortName = 'native_geofence_port';
const String _geofenceIdSeparator = '::';

String _geofenceNameFromId(String id) {
  final separatorIndex = id.indexOf(_geofenceIdSeparator);
  if (separatorIndex == -1) {
    return id;
  }
  return id.substring(separatorIndex + _geofenceIdSeparator.length);
}

@pragma('vm:entry-point')
Future<void> geofenceCallback(GeofenceCallbackParams params) async {
  WidgetsFlutterBinding.ensureInitialized();

  final notifications = FlutterLocalNotificationsPlugin();
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );
  await notifications.initialize(initSettings);

  final event = params.event;
  if (event != GeofenceEvent.enter && event != GeofenceEvent.exit) {
    return;
  }

  final port = IsolateNameServer.lookupPortByName(_geofencePortName);

  for (final geofence in params.geofences) {
    final name = _geofenceNameFromId(geofence.id);
    final title = event == GeofenceEvent.enter
        ? 'Entered: $name'
        : 'Exited: $name';
    final body = 'Geofence ${event.name} detected.';

    port?.send({
      'id': geofence.id,
      'event': event.name,
      'timestamp': DateTime.now().toIso8601String(),
    });

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'nearby_alerts',
        'Nearby Alerts',
        channelDescription: 'Alerts when you are close to a saved location.',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    );

    await notifications.show(
      geofence.id.hashCode ^ event.index,
      title,
      body,
      details,
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NearMeApp());
}

class NearMeApp extends StatelessWidget {
  const NearMeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Near Me Alerts',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final ReceivePort _geofencePort = ReceivePort();

  final Map<String, bool> _insideState = {};

  List<GeoTarget> _targets = [];
  Position? _position;
  StreamSubscription<Position>? _positionSubscription;

  String _status = 'Initializing...';
  String _permissionStatus = 'Unknown';
  String _lastEvent = 'None';
  bool _geofencesRegistered = false;
  bool _needsSettings = false;
  LocationAccuracyStatus? _accuracyStatus;

  @override
  void initState() {
    super.initState();
    IsolateNameServer.removePortNameMapping(_geofencePortName);
    IsolateNameServer.registerPortWithName(
      _geofencePort.sendPort,
      _geofencePortName,
    );
    _geofencePort.listen(_handleGeofenceMessage);
    _initialize();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _geofencePort.close();
    IsolateNameServer.removePortNameMapping(_geofencePortName);
    super.dispose();
  }

  Future<void> _initialize() async {
    await _initNotifications();
    await _loadTargets();
    await NativeGeofenceManager.instance.initialize();

    final permissions = await _ensurePermissions();
    if (!permissions.locationGranted) {
      return;
    }

    if (permissions.alwaysGranted && permissions.preciseLocation) {
      await _registerGeofences();
    } else {
      setState(() {
        _geofencesRegistered = false;
        if (!permissions.alwaysGranted) {
          _status =
              'Background geofences need "Allow all the time" location permission.';
        } else {
          _status = 'Precise location is required for geofences.';
        }
      });
    }
    await _startLocationStream();
  }

  void _handleGeofenceMessage(dynamic message) {
    if (message is! Map) {
      return;
    }

    final id = message['id'] as String?;
    final event = message['event'] as String?;
    final timestamp = message['timestamp'] as String?;

    if (id == null || event == null) {
      return;
    }

    setState(() {
      final displayName = _geofenceNameFromId(id);
      _lastEvent = timestamp == null
          ? '$event: $displayName'
          : '$event: $displayName @ $timestamp';
      if (event == GeofenceEvent.enter.name) {
        _insideState[id] = true;
      } else if (event == GeofenceEvent.exit.name) {
        _insideState[id] = false;
      }
    });
  }

  Future<void> _initNotifications() async {
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );

    await _notifications.initialize(initSettings);
  }

  Future<void> _loadTargets() async {
    try {
      final raw = await rootBundle.loadString('assets/coordinates.json');
      final data = jsonDecode(raw) as List<dynamic>;
      final targets = data
          .map((item) => GeoTarget.fromJson(item as Map<String, dynamic>))
          .toList();
      setState(() {
        _targets = targets;
        _status = 'Loaded ${targets.length} saved locations.';
      });
    } catch (error) {
      setState(() {
        _status = 'Failed to load saved locations: $error';
      });
    }
  }

  Future<_PermissionResult> _ensurePermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _status = 'Location services are disabled.';
        _permissionStatus = 'Location services disabled';
        _needsSettings = false;
      });
      return const _PermissionResult(
        locationGranted: false,
        alwaysGranted: false,
        notificationsGranted: false,
        needsSettings: false,
      );
    }

    var locationStatus = await Permission.location.status;
    if (!locationStatus.isGranted) {
      locationStatus = await Permission.location.request();
    }
    final locationGranted = locationStatus.isGranted;
    if (!locationGranted) {
      setState(() {
        _permissionStatus = 'Location permission denied.';
        _needsSettings = locationStatus.isPermanentlyDenied;
      });
      return _PermissionResult(
        locationGranted: false,
        alwaysGranted: false,
        notificationsGranted: false,
        needsSettings: locationStatus.isPermanentlyDenied,
      );
    }

    var alwaysStatus = await Permission.locationAlways.status;
    if (!alwaysStatus.isGranted) {
      alwaysStatus = await Permission.locationAlways.request();
    }
    final alwaysGranted = alwaysStatus.isGranted;

    var preciseLocation = true;
    if (Platform.isAndroid) {
      final accuracy = await Geolocator.getLocationAccuracy();
      preciseLocation = accuracy == LocationAccuracyStatus.precise;
      _accuracyStatus = accuracy;
    } else {
      _accuracyStatus = null;
    }

    var notificationStatus = await Permission.notification.status;
    if (!notificationStatus.isGranted) {
      notificationStatus = await Permission.notification.request();
    }
    setState(() {
      final locationText =
          alwaysGranted ? 'Location: always' : 'Location: while in use';
      final notificationText = notificationStatus.isGranted
          ? 'Notifications: granted'
          : 'Notifications: denied';
      _permissionStatus = '$locationText • $notificationText';
      _needsSettings = locationStatus.isPermanentlyDenied ||
          alwaysStatus.isPermanentlyDenied ||
          notificationStatus.isPermanentlyDenied ||
          !preciseLocation;
    });

    return _PermissionResult(
      locationGranted: locationGranted,
      alwaysGranted: alwaysGranted,
      notificationsGranted: notificationStatus.isGranted,
      needsSettings: _needsSettings,
      preciseLocation: preciseLocation,
    );
  }

  Future<void> _registerGeofences() async {
    final permissions = await _ensurePermissions();
    if (!permissions.locationGranted ||
        !permissions.alwaysGranted ||
        !permissions.preciseLocation) {
      setState(() {
        _geofencesRegistered = false;
        _status = permissions.preciseLocation
            ? 'Location permissions are required before registering geofences.'
            : 'Enable precise location to register geofences.';
      });
      return;
    }

    if (_targets.isEmpty) {
      setState(() {
        _status = 'No saved locations to monitor.';
      });
      return;
    }

    try {
      await NativeGeofenceManager.instance.removeAllGeofences();

      for (final target in _targets) {
        final radius = target.radiusMeters ?? defaultRadiusMeters;
        final geofence = Geofence(
          id: target.geofenceId,
          location: Location(
            latitude: target.latitude,
            longitude: target.longitude,
          ),
          radiusMeters: radius,
          triggers: const {GeofenceEvent.enter, GeofenceEvent.exit},
          iosSettings: const IosGeofenceSettings(initialTrigger: true),
          androidSettings: const AndroidGeofenceSettings(
            initialTriggers: {GeofenceEvent.enter},
            notificationResponsiveness: Duration(minutes: 1),
          ),
        );

        await NativeGeofenceManager.instance.createGeofence(
          geofence,
          geofenceCallback,
        );
      }

      final active = await NativeGeofenceManager.instance
          .getRegisteredGeofences();
      setState(() {
        _geofencesRegistered = true;
        _status = 'Registered ${active.length} geofences.';
      });
    } on NativeGeofenceException catch (error) {
      setState(() {
        _geofencesRegistered = false;
        _status = 'Geofence error: ${error.code.name}';
      });
    } catch (error) {
      setState(() {
        _geofencesRegistered = false;
        _status = 'Geofence error: $error';
      });
    }
  }

  Future<void> _startLocationStream() async {
    _positionSubscription?.cancel();
    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    _positionSubscription =
        Geolocator.getPositionStream(locationSettings: settings).listen(
          (position) {
            setState(() {
              _position = position;
            });
          },
          onError: (error) {
            setState(() {
              _status = 'Location error: $error';
            });
          },
        );

    await _refreshOnce();
  }

  Future<void> _refreshOnce() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _position = position;
      });
    } catch (error) {
      setState(() {
        _status = 'Unable to get current position: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final position = _position;

    return Scaffold(
      appBar: AppBar(title: const Text('Near Me Alerts')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Status',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(_status),
                  const SizedBox(height: 8),
                  Text('Permissions: $_permissionStatus'),
                  if (_accuracyStatus == LocationAccuracyStatus.reduced)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Precise location is off. Turn it on in Settings.',
                        style: TextStyle(color: Colors.orange),
                      ),
                    ),
                  if (_needsSettings) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Permissions are blocked. Use Settings to enable them.',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    _geofencesRegistered
                        ? 'Geofences: active'
                        : 'Geofences: inactive',
                  ),
                  const SizedBox(height: 8),
                  Text('Last geofence event: $_lastEvent'),
                  const SizedBox(height: 12),
                  Text(
                    position == null
                        ? 'Current position: unknown'
                        : 'Current position: ${position.latitude.toStringAsFixed(6)}, '
                              '${position.longitude.toStringAsFixed(6)}',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _refreshOnce,
                        child: const Text('Refresh Location'),
                      ),
                      OutlinedButton(
                        onPressed: _registerGeofences,
                        child: const Text('Re-register Geofences'),
                      ),
                      if (_needsSettings)
                        TextButton(
                          onPressed: openAppSettings,
                          child: const Text('Open Settings'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Saved locations (${_targets.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final target in _targets)
            _TargetTile(
              target: target,
              distanceMeters: position == null
                  ? null
                  : Geolocator.distanceBetween(
                      position.latitude,
                      position.longitude,
                      target.latitude,
                      target.longitude,
                    ),
              inside: _insideState[target.geofenceId] ?? false,
            ),
        ],
      ),
    );
  }
}

class _PermissionResult {
  const _PermissionResult({
    required this.locationGranted,
    required this.alwaysGranted,
    required this.notificationsGranted,
    required this.needsSettings,
    required this.preciseLocation,
  });

  final bool locationGranted;
  final bool alwaysGranted;
  final bool notificationsGranted;
  final bool needsSettings;
  final bool preciseLocation;
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.target,
    required this.distanceMeters,
    required this.inside,
  });

  final GeoTarget target;
  final double? distanceMeters;
  final bool inside;

  @override
  Widget build(BuildContext context) {
    final radius = target.radiusMeters ?? defaultRadiusMeters;

    return Card(
      child: ListTile(
        title: Text(target.name),
        subtitle: Text(
          'Lat ${target.latitude.toStringAsFixed(5)}, '
          'Lng ${target.longitude.toStringAsFixed(5)}',
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('Radius ${radius.toStringAsFixed(0)}m'),
            const SizedBox(height: 4),
            Text(
              distanceMeters == null
                  ? 'Distance --'
                  : 'Distance ${distanceMeters!.toStringAsFixed(0)}m',
              style: TextStyle(
                color: inside ? Colors.green : Colors.grey[700],
                fontWeight: inside ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GeoTarget {
  GeoTarget({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radiusMeters,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double? radiusMeters;

  String get geofenceId => '$id$_geofenceIdSeparator$name';

  factory GeoTarget.fromJson(Map<String, dynamic> json) {
    return GeoTarget(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Saved place',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      radiusMeters: (json['radiusMeters'] as num?)?.toDouble(),
    );
  }
}
