import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math'; // For min function
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

// --- CONFIGURATION ---
const geoapifyApiKey = '1184478395cc4017a33a122f110602b7';
// IMPORTANT: Use the same IP as the patient app
const serverUrl = 'http://10.0.2.2:3000'; // Example for emulator

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
  List<Marker> _markers = []; // Now only holds destination markers
  Marker? _driverMarker;
  LatLng? _driverPosition;
  bool _isLoading = false;

  LatLng? _currentDestination; // --- NEW: To store the active destination for rerouting ---

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
    try {
      _socket = IO.io(serverUrl, IO.OptionBuilder()
          .setTransports(['websocket'])
          .enableReconnection() // Ensure reconnection is enabled
          .disableAutoConnect()
          .build());
      _socket!.connect();

      _socket!.onConnect((_) async {
        print('DRIVER: Connected to server: ${_socket!.id}');
        await _updateDriverPositionAndEmitOnline();
      });

      _socket!.on('start-ride', (data) {
        if (mounted) {
          print("DRIVER: Ride request ('start-ride') received!");
          if (data is Map<String, dynamic> && _isValidRideData(data)) {
            _startRide(data);
          } else {
            print("DRIVER: ERROR: Received invalid ride data from server: $data");
            _showErrorSnackBar("Received invalid ride data.");
          }
        }
      });

      // --- Listen for the ride cancellation event ---
      _socket!.on('ride-canceled', (_) {
        if (mounted) {
          print("DRIVER: 'ride-canceled' event received from server.");
          _showInfoSnackBar("The ride was canceled by the patient.");
          _resetToWaiting(); // Reset the driver's UI
        }
      });

      _socket!.onDisconnect((reason) => print('DRIVER: Disconnected. Reason: $reason'));
      _socket!.onReconnectAttempt((attempt) => print('DRIVER: Attempting to reconnect (attempt $attempt)...'));
      _socket!.onReconnect((_) async {
        print('DRIVER: Reconnected!');
        await _updateDriverPositionAndEmitOnline();
      });
      _socket!.onConnectError((data) => print('DRIVER: Connection Error: $data'));
      _socket!.onError((data) => print('DRIVER: Socket Error: $data'));

    } catch (e) {
      print("DRIVER: CRITICAL ERROR setting up socket connection: $e");
      _showErrorSnackBar("Failed to connect to server.");
    }
  }

  bool _isValidRideData(Map<String, dynamic> data) {
    final pickup = data['route']?['pickup'];
    final dropoff = data['route']?['dropoff'];
    return pickup != null && pickup['lat'] is num && pickup['lng'] is num &&
        dropoff != null && dropoff['lat'] is num && dropoff['lng'] is num;
  }

  Future<void> _updateDriverPositionAndEmitOnline() async {
    if (_currentState != DriverState.waiting) return;

    try {
      setState(() => _isLoading = true);
      final position = await _determinePosition();
      final currentLatLng = LatLng(position.latitude, position.longitude);

      if (!mounted) return;

      setState(() {
        _driverPosition = currentLatLng;
        if (_mapController != null) {
          _mapController.move(_driverPosition!, 14);
        }
        _isLoading = false;
      });

      final location = {'lat': position.latitude, 'lng': position.longitude};
      _socket?.emit('driver-online', {'name': 'Ambulance 1', 'location': location});
      print('DRIVER: "driver-online" event emitted with location.');
    } catch (e) {
      print("DRIVER: ERROR: Could not get initial driver location: $e");
      if (mounted) {
        _showErrorSnackBar("Could not get your location. Check permissions/GPS.");
      }
      _socket?.emit('driver-online', {'name': 'Ambulance 1'});
    } finally {
      if(mounted) setState(() => _isLoading = false);
    }
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
                errorTileCallback: (tile, error, stack) => print("Map Tile Error for tile $tile: $error"),
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
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  // --- Logic Methods ---
  Future<void> _startRide(Map<String, dynamic> rideDetails) async {
    print('DRIVER: _startRide function called.');
    if (!mounted) return;

    setState(() {
      _currentRideDetails = rideDetails;
      _currentState = DriverState.enRouteToPickup;
      _isLoading = true;
      _routePoints = [];
      _markers = [];
      _driverMarker = null;
    });

    try {
      final driverPos = await _determinePosition();
      final driverLatLng = LatLng(driverPos.latitude, driverPos.longitude);
      _driverPosition = driverLatLng;

      final patientLocationData = rideDetails['route']?['pickup'];
      if (!_isValidCoordinateData(patientLocationData)) throw Exception("Invalid patient location.");
      final patientLatLng = LatLng((patientLocationData['lat'] as num).toDouble(), (patientLocationData['lng'] as num).toDouble());

      _currentDestination = patientLatLng;

      if (!_isValidLatLng(driverLatLng) || !_isValidLatLng(patientLatLng)) throw Exception("Invalid coordinates.");

      if (mounted) _updateDriverMarker(driverLatLng);

      await _displayRoute(driverLatLng, _currentDestination!);

      _locationBroadcastTimer?.cancel();

      _locationBroadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
        try {
          if (!mounted || _currentState == DriverState.waiting) { timer.cancel(); return; }

          final pos = await _determinePosition();
          final newLatLng = LatLng(pos.latitude, pos.longitude);

          if (!_isValidLatLng(newLatLng)) { print("DRIVER: WARN: Skipping location broadcast: invalid coordinates."); return; }

          if (mounted) {
            setState(() {
              _driverPosition = newLatLng;
              _updateDriverMarker(newLatLng);
            });
          }
          _socket?.emit('driver-location-update', {'lat': newLatLng.latitude, 'lng': newLatLng.longitude});

          // --- *** THIS IS THE FIX (REROUTE LOGIC) *** ---
          if (_currentDestination != null && !_isLoading && _driverPosition != null) {

            const rerouteThreshold = 75; // 75 meters, for when we *have* a route
            const plotInitialRouteThreshold = 25; // 25 meters, for when we *don't* have a route

            if (_routePoints.isNotEmpty) {
              // We HAVE a route. Check if we are off it.
              double minDistanceToRoute = double.infinity;
              for (final point in _routePoints) {
                final distance = Geolocator.distanceBetween(
                    newLatLng.latitude, newLatLng.longitude,
                    point.latitude, point.longitude
                );
                if (distance < minDistanceToRoute) {
                  minDistanceToRoute = distance;
                }
              }
              print("DRIVER: Distance to route: ${minDistanceToRoute.toStringAsFixed(2)} meters");

              if (minDistanceToRoute > rerouteThreshold) {
                print("--- DRIVER OFF-ROUTE: Rerouting... ---");
                _displayRoute(newLatLng, _currentDestination!);
              }
            } else {
              // We HAVE NO route. Check if we are far enough from the destination to need one.
              double distanceToDestination = Geolocator.distanceBetween(
                  newLatLng.latitude, newLatLng.longitude,
                  _currentDestination!.latitude, _currentDestination!.longitude
              );
              print("DRIVER: No route. Distance to destination: ${distanceToDestination.toStringAsFixed(2)} meters");

              if (distanceToDestination > plotInitialRouteThreshold) {
                print("--- DRIVER HAS NO ROUTE AND IS MOVING: Plotting route... ---");
                _displayRoute(newLatLng, _currentDestination!);
              }
            }
          }
          // --- *** END OF FIX *** ---

        } catch (e) {
          print('DRIVER: Error in location broadcast timer: $e');
        }
      });

    } catch(e) {
      print('DRIVER: CRITICAL ERROR in _startRide: $e');
      if(mounted) {
        _showErrorSnackBar('Error starting ride: ${e.toString().substring(0, min(e.toString().length, 100))}');
        _resetToWaiting();
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _displayRoute(LatLng start, LatLng end) async {
    print("DRIVER: Calculating route from $start to $end");
    if (!_isValidLatLng(start) || !_isValidLatLng(end)) {
      _showErrorSnackBar("Cannot calculate route: Invalid coordinates.");
      _resetToWaiting();
      return;
    }

    if (_isLoading) {
      print("DRIVER: Already loading a route, skipping new request.");
      return;
    }
    setState(() => _isLoading = true);

    final url = 'https://api.geoapify.com/v1/routing?waypoints=${start.latitude},${start.longitude}|${end.latitude},${end.longitude}&mode=drive&apiKey=$geoapifyApiKey';
    print("DRIVER: Routing API URL: $url");

    List<LatLng> points = [];

    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      print("DRIVER: Routing API Status Code: ${response.statusCode}");

      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        if (decoded['features'] == null || (decoded['features'] as List).isEmpty) {
          throw Exception('No route features found.');
        }

        final geometry = decoded['features'][0]?['geometry']?['coordinates']?[0];
        if (geometry == null || geometry is! List) {
          throw Exception('Invalid route geometry.');
        }

        points = geometry.map<LatLng?>((p) {
          if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
            final lat = p[1] as num;
            final lng = p[0] as num;
            if (lat.isFinite && lng.isFinite) { return LatLng(lat.toDouble(), lng.toDouble()); }
          } return null;
        }).whereType<LatLng>().toList();

        if (points.isEmpty) {
          print("DRIVER: WARN: Route geometry is empty. (Start/End might be identical)");
        }

        print("DRIVER: Route calculated successfully (${points.length} points). Updating state.");

        setState(() {
          _routePoints = points;
          final endIcon = Icon(
              _currentState == DriverState.enRouteToPickup ? Icons.person_pin_circle : Icons.local_hospital,
              color: Colors.blue, size: 40
          );
          _markers = [ Marker(point: end, child: endIcon) ];
          _updateDriverMarker(start);
        });

        // --- Send route to server for dashboard ---
        _socket?.emit('driver-route-update', {
          'route': points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
          'driverState': _currentState.toString()
        });

        try {
          await Future.delayed(const Duration(milliseconds: 150));
          if (mounted) {
            if (points.length < 2 || (start.latitude == end.latitude && start.longitude == end.longitude)) {
              _mapController.move(start, 15); // Just zoom to the single point
            } else {
              _mapController.fitCamera(CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(100)));
            }
          }
        } catch (mapError) {
          print("DRIVER: ERROR fitting map camera: $mapError.");
          _showErrorSnackBar("Error displaying route map.");
        }

      } else {
        print("DRIVER: ERROR: Failed route fetch. Status: ${response.statusCode}, Body: ${response.body}");
        throw Exception('API Error: ${response.statusCode}');
      }
    } catch (e) {
      print("DRIVER: CRITICAL ERROR in _displayRoute: $e");
      if(mounted) {
        _showErrorSnackBar('Could not calculate route: ${e.toString().substring(0, min(e.toString().length, 100))}');
      }
    } finally {
      if(mounted) setState(() => _isLoading = false);
    }
  }

  void _updateDriverMarker(LatLng position) {
    if(!_isValidLatLng(position)) {
      print("DRIVER: WARN: Invalid position for driver marker: $position");
      return;
    }
    final ambulanceIcon = Marker(
      point: position,
      width: 40, height: 40,
      child: const Icon(Icons.directions_car, color: Colors.green, size: 40),
    );
    if (mounted) {
      setState(() => _driverMarker = ambulanceIcon);
    }
  }

  bool _isValidLatLng(LatLng? latLng) {
    if (latLng == null) return false;
    return latLng.latitude >= -90 && latLng.latitude <= 90 &&
        latLng.longitude >= -180 && latLng.longitude <= 180 &&
        latLng.latitude.isFinite && latLng.longitude.isFinite;
  }

  void _handleActionButton() {
    if (_currentState == DriverState.enRouteToPickup) {
      if (_currentRideDetails == null) { _showErrorSnackBar("No ride details."); _resetToWaiting(); return; }

      _socket?.emit('driver-picked-up-patient', {'patientId': _currentRideDetails!['patientId']});

      final patientLocationData = _currentRideDetails!['route']?['pickup'];
      final hospitalLocationData = _currentRideDetails!['route']?['dropoff'];

      if (_isValidCoordinateData(patientLocationData) && _isValidCoordinateData(hospitalLocationData))
      {
        final patientLatLng = LatLng((patientLocationData['lat'] as num).toDouble(), (patientLocationData['lng'] as num).toDouble());
        final hospitalLatLng = LatLng((hospitalLocationData['lat'] as num).toDouble(), (hospitalLocationData['lng'] as num).toDouble());

        _currentDestination = hospitalLatLng;

        setState(() => _currentState = DriverState.enRouteToDropoff);
        _displayRoute(patientLatLng, _currentDestination!); // Calculate route to hospital

      } else {
        _showErrorSnackBar("Invalid location data for next stage.");
        _resetToWaiting();
      }

    } else {
      _finishRide();
    }
  }

  bool _isValidCoordinateData(dynamic locationData) {
    return locationData != null && locationData['lat'] is num && locationData['lng'] is num;
  }


  void _finishRide() {
    _locationBroadcastTimer?.cancel();
    _socket?.emit('ride-finished', { 'location': { 'lat': _driverPosition?.latitude, 'lng': _driverPosition?.longitude } });
    _resetToWaiting();
  }

  void _resetToWaiting() {
    _locationBroadcastTimer?.cancel(); // Stop broadcasting

    _socket?.emit('driver-route-update', {
      'route': [],
      'driverState': DriverState.waiting.toString()
    });

    if (mounted) {
      setState(() {
        _currentState = DriverState.waiting;
        _routePoints = [];
        _markers = [];
        _driverMarker = null;
        _currentRideDetails = null;
        _currentDestination = null;
      });
    }
  }

  Future<Position> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return Future.error('Location services are disabled.');

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return Future.error('Location permissions denied');
    }

    if (permission == LocationPermission.deniedForever) return Future.error('Location permissions permanently denied');

    return await Geolocator.getCurrentPosition();
  }

  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  void _showInfoSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
    }
  }
}