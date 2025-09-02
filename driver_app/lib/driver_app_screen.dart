import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

// --- CONFIGURATION ---
const geoapifyApiKey = '1184478395cc4017a33a122f110602b7';
// IMPORTANT: Use the same IP as the patient app
const serverUrl = 'http://10.0.2.2:3000';

// --- App State ---
enum DriverState { waiting, enRouteToPickup, enRouteToDropoff }

// --- Main Widget ---
class DriverAppScreen extends StatefulWidget {
  const DriverAppScreen({Key? key}) : super(key: key);
  @override
  _DriverAppScreenState createState() => _DriverAppScreenState();
}

class _DriverAppScreenState extends State<DriverAppScreen> {
  // --- State ---
  IO.Socket? _socket;
  final MapController _mapController = MapController();

  DriverState _currentState = DriverState.waiting;
  Map<String, dynamic>? _currentRideDetails;
  Timer? _locationBroadcastTimer;

  List<LatLng> _routePoints = [];
  List<Marker> _markers = [];
  Marker? _driverMarker;
  LatLng? _driverPosition;

  @override
  void initState() {
    super.initState();
    _setupSocketConnection();
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _locationBroadcastTimer?.cancel();
    super.dispose();
  }

  void _setupSocketConnection() {
    _socket = IO.io(serverUrl, IO.OptionBuilder()
        .setTransports(['websocket']).disableAutoConnect().build());
    _socket!.connect();

    _socket!.onConnect((_) async {
      print('Driver connected: ${_socket!.id}');
      try {
        final position = await _determinePosition();
        setState(() {
          _driverPosition = LatLng(position.latitude, position.longitude);
          _mapController.move(_driverPosition!, 14);
        });
        final location = {'lat': position.latitude, 'lng': position.longitude};
        _socket!.emit('driver-online', {'name': 'Ambulance 1', 'location': location});
      } catch (e) {
        print("Could not get initial location: $e");
      }
    });

    _socket!.on('start-ride', (data) {
      if (mounted) {
        print("Ride request received!");
        // Add robust data validation before starting the ride.
        if (data is Map<String, dynamic> && data['route']?['pickup']?['lat'] != null) {
          _startRide(data);
        } else {
          print("Received invalid ride data from server.");
        }
      }
    });
  }

  // --- UI Build Methods ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Dashboard'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _driverPosition ?? LatLng(12.9141, 74.8560),
              initialZoom: 14,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.driver_app',
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(polylines: [Polyline(points: _routePoints, color: Colors.blue, strokeWidth: 5)]),
              MarkerLayer(markers: _markers),
              if (_driverMarker != null) MarkerLayer(markers: [_driverMarker!]),
            ],
          ),
          if (_currentState != DriverState.waiting)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Card(
                elevation: 10,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        _currentState == DriverState.enRouteToPickup ? 'Driving to Patient' : 'Driving to Destination',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: _handleActionButton,
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 50),
                            backgroundColor: _currentState == DriverState.enRouteToDropoff ? Colors.red : Colors.green),
                        child: Text(_currentState == DriverState.enRouteToPickup ? 'Patient Picked Up' : 'Finish Ride'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_currentState == DriverState.waiting)
            Center(
              child: Card(
                elevation: 10,
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('You are online.', style: TextStyle(fontSize: 18)),
                      Text('Waiting for requests...'),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- Logic Methods ---
  Future<void> _startRide(Map<String, dynamic> rideDetails) async {
    setState(() {
      _currentRideDetails = rideDetails;
      _currentState = DriverState.enRouteToPickup;
    });

    try {
      final driverPos = await _determinePosition();
      final driverLatLng = LatLng(driverPos.latitude, driverPos.longitude);

      final patientLocation = rideDetails['route']['pickup'];
      final patientLatLng = LatLng(patientLocation['lat'], patientLocation['lng']);

      await _displayRoute(driverLatLng, patientLatLng);

      _locationBroadcastTimer?.cancel();
      _locationBroadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
        try {
          final pos = await _determinePosition();
          final newLatLng = LatLng(pos.latitude, pos.longitude);

          setState(() {
            _driverPosition = newLatLng;
            _driverMarker = Marker(
              point: newLatLng,
              width: 40, height: 40,
              child: const Icon(Icons.directions_car, color: Colors.green, size: 40),
            );
          });

          _socket?.emit('driver-location-update', {'lat': newLatLng.latitude, 'lng': newLatLng.longitude});
        } catch (e) {
          print('Error broadcasting location: $e');
        }
      });

    } catch(e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not get location to start ride: $e')));
    }
  }

  Future<void> _displayRoute(LatLng start, LatLng end) async {
    final url = 'https://api.geoapify.com/v1/routing?waypoints=${start.latitude},${start.longitude}|${end.latitude},${end.longitude}&mode=drive&apiKey=$geoapifyApiKey';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200 && mounted) {
        final decoded = jsonDecode(response.body);

        if (decoded['features'] == null || (decoded['features'] as List).isEmpty) {
          throw Exception('Route not found in API response.');
        }

        final geometry = decoded['features'][0]['geometry']['coordinates'][0];
        final points = geometry.map<LatLng>((p) => LatLng(p[1], p[0])).toList();

        if (points.isEmpty) {
          throw Exception('Route geometry is empty.');
        }

        setState(() {
          _routePoints = points;
          _markers = [ Marker(point: end, child: Icon(_currentState == DriverState.enRouteToPickup ? Icons.person_pin_circle : Icons.local_hospital, color: Colors.blue, size: 40)),];
          _driverMarker = Marker(point: start, width: 40, height: 40, child: const Icon(Icons.directions_car, color: Colors.green, size: 40));
        });
        _mapController.fitCamera(CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(100)));
      } else {
        throw Exception('Failed to fetch route. Status: ${response.statusCode}');
      }
    } catch (e) {
      print("Error in _displayRoute: $e");
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not calculate route: $e')));
    }
  }

  void _handleActionButton() {
    if (_currentState == DriverState.enRouteToPickup) {
      _socket?.emit('driver-picked-up-patient', {'patientId': _currentRideDetails!['patientId']});
      final patientLocation = _currentRideDetails!['route']['pickup'];
      final hospitalLocation = _currentRideDetails!['route']['dropoff'];
      final patientLatLng = LatLng(patientLocation['lat'], patientLocation['lng']);
      final hospitalLatLng = LatLng(hospitalLocation['lat'], hospitalLocation['lng']);
      _displayRoute(patientLatLng, hospitalLatLng);
      setState(() {
        _currentState = DriverState.enRouteToDropoff;
      });
    } else {
      _finishRide();
    }
  }

  void _finishRide() {
    _locationBroadcastTimer?.cancel();
    _socket?.emit('ride-finished', { 'location': { 'lat': _driverPosition?.latitude, 'lng': _driverPosition?.longitude } });
    setState(() {
      _currentState = DriverState.waiting;
      _routePoints = [];
      _markers = [];
      _driverMarker = null;
    });
  }

  Future<Position> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error('Location permissions are permanently denied, we cannot request permissions.');
    }

    return await Geolocator.getCurrentPosition();
  }
}

