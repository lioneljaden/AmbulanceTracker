import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math'; // Import the math library for 'min' function
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:uuid/uuid.dart'; // Import the new package

// --- CONFIGURATION ---
const geoapifyApiKey = '1184478395cc4017a33a122f110602b7';
// IMPORTANT: Replace with your PC's local IP address to test on a physical device.
// Use 'http://10.0.2.2:3000' for the Android emulator.
const serverUrl = 'http://10.0.2.2:3000'; // Example for emulator


// --- Data Models ---
class Place {
  final String name;
  final LatLng location;
  Place(this.name, this.location);

  @override
  String toString() => 'Place(name: $name, location: $location)';
}

class SimpleRoute {
  final Place pickup;
  final Place dropoff;
  SimpleRoute(this.pickup, this.dropoff);
  Map<String, dynamic> toJson() => {
    'pickup': {'name': pickup.name, 'lat': pickup.location.latitude, 'lng': pickup.location.longitude},
    'dropoff': {'name': dropoff.name, 'lat': dropoff.location.latitude, 'lng': dropoff.location.longitude}
  };
}

// --- App State Enum for Cleaner UI Management ---
enum AppState { booking, confirmation, status }

// --- Main App Screen Widget ---
class PatientAppScreen extends StatefulWidget {
  const PatientAppScreen({Key? key}) : super(key: key);
  @override
  _PatientAppScreenState createState() => _PatientAppScreenState();
}

class _PatientAppScreenState extends State<PatientAppScreen> {
  // --- State ---
  IO.Socket? _socket;
  final MapController _mapController = MapController();

  Place? _pickupPlace;
  Place? _dropPlace;

  List<LatLng> _routePoints = []; // Original route (Pickup -> Dropoff)
  List<LatLng> _ambulanceRoutePoints = []; // --- NEW: Live route from driver
  List<Marker> _markers = [];
  Marker? _ambulanceMarker;

  // UI State
  AppState _currentState = AppState.booking;
  String _etaMessage = "Calculating ETA...";
  String _driverInfo = "";
  bool _isLoading = false; // For full-screen loader

  // Autocomplete
  final _pickupController = TextEditingController();
  final _dropoffController = TextEditingController();
  List<Place> _pickupSuggestions = [];
  List<Place> _dropSuggestions = [];
  Timer? _debounce;
  String? _activeInputField;

  // NEW: A permanent, unique ID for this patient/device
  final String _myPermanentId = Uuid().v4();

  @override
  void initState() {
    super.initState();
    _setupSocketConnection();
    _initializeCurrentLocation();
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _pickupController.dispose();
    _dropoffController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _setupSocketConnection() {
    try {
      _socket = IO.io(serverUrl, IO.OptionBuilder()
          .setTransports(['websocket'])
          .enableReconnection()
          .disableAutoConnect()
          .build());

      // --- NEW: More detailed debug logs ---
      _socket!.onConnect((_) => print('PATIENT: Connected to server: ${_socket!.id} (My ID: $_myPermanentId)'));
      _socket!.onConnectError((data) => print('PATIENT: Connection Error: $data'));
      _socket!.onError((data) => print('PATIENT: Socket Error: $data'));
      _socket!.onDisconnect((_) => print('PATIENT: Disconnected from server.'));
      _socket!.onReconnectAttempt((attempt) => print('PATIENT: Reconnecting... (attempt $attempt)'));
      _socket!.onReconnect((_) => print('PATIENT: Reconnected!'));
      // --- END NEW ---

      _socket!.on('booking-accepted', (data) {
        if (mounted) setState(() {
          print('PATIENT: Booking accepted!');
          _currentState = AppState.status;
          _driverInfo = 'Driver: ${data['driverName']} | Vehicle: ${data['vehicle']}';
          if (data['driverLocation'] != null) {
            _addAmbulanceMarker(LatLng(data['driverLocation']['lat'], data['driverLocation']['lng']));
          } else if (_pickupPlace != null) {
            // Fallback if location not sent
            _addAmbulanceMarker(_pickupPlace!.location);
          } else {
            print("PATIENT: Error: _pickupPlace was null when booking accepted.");
          }
        });
      });

      _socket!.on('ambulance-location-update', (data) {
        if (mounted) _addAmbulanceMarker(LatLng(data['lat'], data['lng']));
      });

      _socket!.on('ambulance-route-update', (data) {
        // --- NEW: Debug log ---
        print("PATIENT: Received 'ambulance-route-update'");
        if (mounted) {
          final route = data['route'] as List<dynamic>;
          if (route.isEmpty) {
            print("PATIENT: Route is empty, clearing line.");
            setState(() => _ambulanceRoutePoints = []);
            return;
          }
          final points = route.map<LatLng>((p) => LatLng(p['lat'], p['lng'])).toList();
          print("PATIENT: Setting new route with ${points.length} points.");
          setState(() {
            _ambulanceRoutePoints = points;
          });
        }
      });
      // --- END ---

      _socket!.on('ride-finished', (_) {
        print('PATIENT: Ride finished!');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You have arrived!')));
        _resetToBooking();
      });

      _socket!.connect(); // Explicitly connect

    } catch (e) {
      print("PATIENT: Error setting up socket connection: $e");
    }
  }

  Future<void> _initializeCurrentLocation() async {
    setState(() => _isLoading = true);
    final hasPermission = await _checkAndRequestLocationPermission(context);
    if (!hasPermission) {
      _showErrorSnackBar("Location permission is required to use this app effectively.");
      setState(() => _isLoading = false);
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final place = Place('Current Location', LatLng(position.latitude, position.longitude));
      setState(() {
        _pickupPlace = place;
        _pickupController.text = "Current Location";
        _mapController.move(place.location, 14);
      });
    } catch (e) {
      _showErrorSnackBar("Could not get current location. Please enable GPS.");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- UI Build Methods ---
  @override
  Widget build(BuildContext context) {

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(12.9141, 74.8560),
              initialZoom: 13,
              onTap: (_, __) => _clearAutocompleteFocus(),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.patient_app',
                errorTileCallback: (tile, error, stack) {
                  print("Error loading map tile $tile: $error");
                },
              ),
              // The patient's original route (black)
              if (_routePoints.isNotEmpty)
                PolylineLayer(polylines: [Polyline(points: _routePoints, color: Colors.black, strokeWidth: 5)]),

              // The live ambulance route (solid green)
              if (_ambulanceRoutePoints.isNotEmpty)
                PolylineLayer(polylines: [Polyline(
                  points: _ambulanceRoutePoints,
                  color: Colors.green,
                  strokeWidth: 6,
                )]),

              MarkerLayer(markers: _markers),
              if (_ambulanceMarker != null) MarkerLayer(markers: [_ambulanceMarker!]),
            ],
          ),

          _buildTopBookingPanel(),
          _buildBottomPanel(),

          if (_currentState != AppState.booking)
            Positioned(
              top: 50, left: 20,
              child: FloatingActionButton(
                onPressed: _resetToBooking,
                backgroundColor: Colors.white,
                child: const Icon(Icons.arrow_back, color: Colors.black),
              ),
            ),

          Positioned(
            top: 50, right: 20,
            child: FloatingActionButton(
              onPressed: _handleEmergencyButton,
              backgroundColor: Colors.red,
              heroTag: 'emergency_btn',
              child: const Icon(Icons.emergency, color: Colors.white),
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

  Widget _buildTopBookingPanel() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      top: _currentState == AppState.booking ? 50 : -300,
      left: 20,
      right: 20,
      child: Material(
        elevation: 10,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAutocompleteSection(
                  controller: _pickupController,
                  hint: "Pickup Location",
                  suggestions: _pickupSuggestions,
                  onSelect: (place) => setState(() => _pickupPlace = place),
                  fieldType: 'pickup'
              ),
              const SizedBox(height: 10),
              _buildAutocompleteSection(
                  controller: _dropoffController,
                  hint: "Drop-off Location",
                  suggestions: _dropSuggestions,
                  onSelect: (place) => setState(() => _dropPlace = place),
                  fieldType: 'dropoff'
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _handleFindRoute,
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
                child: const Text('Book'),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      bottom: _currentState == AppState.booking ? -300 : 0,
      left: 0, right: 0,
      child: Card(
        margin: const EdgeInsets.all(20),
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _panelContent(),
          ),
        ),
      ),
    );
  }

  Widget _panelContent() {
    switch (_currentState) {
      case AppState.confirmation: return _buildConfirmationPanel();
      case AppState.status: return _buildStatusPanel();
      default: return Container(key: const ValueKey('empty'));
    }
  }

  Widget _buildConfirmationPanel() {
    return Column(
      key: const ValueKey('confirmation'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Confirm Booking', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 15),
        Text(_etaMessage, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _handleConfirmBooking,
          child: const Text('Confirm Booking'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _showCancelConfirmationDialog,
          child: const Text('Cancel', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
  }

  Widget _buildStatusPanel() {
    return Column(
      key: const ValueKey('status'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Ambulance on its way!', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 15),
        Text(_driverInfo, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _showCancelConfirmationDialog,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Cancel Ride'),
        ),
      ],
    );
  }

  // --- Logic Methods ---
  Future<void> _handleFindRoute() async {
    if (_pickupPlace == null || _dropPlace == null) {
      _showErrorSnackBar('Please select a pickup and drop-off location.');
      return;
    }
    _displayRoute(_pickupPlace!, _dropPlace!);
  }

  Future<void> _displayRoute(Place start, Place end) async {
    setState(() => _isLoading = true);
    final url = 'https://api.geoapify.com/v1/routing?waypoints=${start.location.latitude},${start.location.longitude}|${end.location.latitude},${end.location.longitude}&mode=drive&apiKey=$geoapifyApiKey';

    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 && mounted) {
        final decoded = jsonDecode(response.body);

        if (decoded['features'] == null || (decoded['features'] as List).isEmpty) {
          throw Exception('Route geometry not found in response.');
        }

        final geometry = decoded['features'][0]['geometry']['coordinates'][0];
        final points = geometry.map<LatLng>((p) => LatLng(p[1], p[0])).toList();
        final eta = decoded['features'][0]['properties']['time'] / 60;

        if (points.isEmpty) {
          throw Exception('Calculated route has no points.');
        }

        setState(() {
          _routePoints = points;
          _ambulanceRoutePoints = []; // Clear any old ambulance routes
          _markers = [
            Marker(point: start.location, child: const Icon(Icons.person_pin_circle, color: Colors.blue, size: 40)),
            Marker(point: end.location, child: const Icon(Icons.local_hospital, color: Colors.red, size: 40)),
          ];
          _etaMessage = 'Estimated Time: ${eta.ceil()} mins';
          _currentState = AppState.confirmation;
        });
        await Future.delayed(const Duration(milliseconds: 50));
        _mapController.fitCamera(CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(150)));
      } else {
        throw Exception('Failed to fetch route. Status: ${response.statusCode}');
      }
    } catch (e) {
      print("Error in _displayRoute: $e");
      _showErrorSnackBar('Error calculating route: ${e.toString().substring(0, min(e.toString().length, 100))}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _handleConfirmBooking() {
    if (_pickupPlace == null || _dropPlace == null) {
      _showErrorSnackBar("Pickup or Dropoff location is missing.");
      return;
    }
    final route = SimpleRoute(_pickupPlace!, _dropPlace!);
    _socket?.emit('request-booking', {
      'route': route.toJson(),
      'patientId': _myPermanentId // Send permanent ID
    });
    setState(() {
      _etaMessage = "Searching for nearby drivers...";
      // Hide the original black route to avoid clutter.
      // The new green route will appear when the driver accepts.
      _routePoints = [];
    });
  }

  Future<void> _showCancelConfirmationDialog() async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Cancel Ride?'),
          content: const Text('Are you sure you want to cancel this ride?'),
          actions: <Widget>[
            TextButton(
              child: const Text('No'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Yes, Cancel', style: TextStyle(color: Colors.red)),
              onPressed: () {
                Navigator.of(context).pop();
                _handleCancelRide();
              },
            ),
          ],
        );
      },
    );
  }

  void _handleCancelRide() {
    // Send the permanent ID so the server knows *who* is cancelling
    _socket?.emit('cancel-ride', { 'patientId': _myPermanentId });
    _resetToBooking();
  }

  void _resetToBooking() {
    setState(() {
      _routePoints = [];
      _markers = [];
      _ambulanceMarker = null;
      _ambulanceRoutePoints = [];
      _currentState = AppState.booking;
      _pickupController.clear();
      _dropoffController.clear();
      _pickupSuggestions.clear();
      _dropSuggestions.clear();
      _activeInputField = null;
    });
    // Re-initialize location after a ride is finished or canceled.
    _initializeCurrentLocation();
  }

  void _addAmbulanceMarker(LatLng position) {
    setState(() {
      _ambulanceMarker = Marker(
        point: position, width: 40, height: 40,
        child: const Icon(Icons.directions_car, color: Colors.green, size: 40),
      );
    });
  }

  // --- Autocomplete & Geolocation ---
  void _clearAutocompleteFocus() {
    FocusScope.of(context).unfocus();
    setState(() {
      _pickupSuggestions.clear();
      _dropSuggestions.clear();
      _activeInputField = null;
    });
  }

  Widget _buildAutocompleteSection({
    required TextEditingController controller,
    required String hint,
    required List<Place> suggestions,
    required Function(Place?) onSelect,
    required String fieldType,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(fieldType == 'pickup' ? Icons.my_location : Icons.flag),
            suffixIcon: (controller.text.isNotEmpty)
                ? IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                controller.clear();
                onSelect(null);
                _clearAutocompleteFocus();
              },
            )
                : null,
          ),
          onTap: () => setState(() => _activeInputField = fieldType),
          onChanged: (text) {
            if (fieldType == 'pickup') onSelect(null); else onSelect(null);

            setState(() {
              _activeInputField = fieldType;
              if (fieldType == 'pickup') _pickupSuggestions.clear(); else _dropSuggestions.clear();
            });
            if (_debounce?.isActive ?? false) _debounce!.cancel();
            _debounce = Timer(const Duration(milliseconds: 400), () {
              if (text.length > 2) _fetchAutocomplete(text, fieldType);
            });
          },
        ),
        if (_activeInputField == fieldType && suggestions.isNotEmpty)
          _buildSuggestionsList(suggestions, controller, onSelect, fieldType),
      ],
    );
  }

  Widget _buildSuggestionsList(List<Place> suggestions, TextEditingController controller, Function(Place) onSelect, String fieldType) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [ BoxShadow(color: Colors.black12, blurRadius: 5, spreadRadius: 1) ]
      ),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        itemCount: suggestions.length,
        itemBuilder: (context, index) {
          final place = suggestions[index];
          return ListTile(
            title: Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis,),
            onTap: () {
              controller.text = place.name;
              onSelect(place);
              FocusScope.of(context).unfocus();
              setState(() {
                if (fieldType == "pickup") _pickupSuggestions.clear();
                else _dropSuggestions.clear();
                _activeInputField = null;
              });
            },
          );
        },
      ),
    );
  }

  Future<void> _fetchAutocomplete(String text, String fieldType) async {
    final url = 'https://api.geoapify.com/v1/geocode/autocomplete?text=${Uri.encodeComponent(text)}&apiKey=$geoapifyApiKey';
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200 && mounted) {
        final features = jsonDecode(response.body)['features'] as List<dynamic>;
        final places = features.map((f) {
          final props = f['properties'];
          final lat = props['lat'];
          final lon = props['lon'];
          if (lat is num && lon is num) {
            return Place(props['formatted'] ?? 'Unknown Address', LatLng(lat.toDouble(), lon.toDouble()));
          }
          return null;
        }).whereType<Place>().toList();

        setState(() {
          if (fieldType == "pickup") _pickupSuggestions = places;
          else _dropSuggestions = places;
        });
      } else {
        print("Autocomplete failed: ${response.statusCode}");
      }
    } catch (e) {
      print("Error fetching autocomplete: $e");
    }
  }

  // --- EMERGENCY MODAL LOGIC ---
  Future<void> _handleEmergencyButton() async {
    if (_pickupPlace == null) {
      _showErrorSnackBar("Current location not found. Please wait or select a pickup location.");
      return;
    }
    await _findNearestHospitalAndRoute(_pickupPlace!);
  }

  Future<void> _findNearestHospitalAndRoute(Place pickup) async {
    setState(() {
      _isLoading = true;
      _pickupPlace = pickup;
    });

    if (mounted) _showInfoSnackBar('Finding nearest hospital...');

    try {
      final hospital = await _findNearestHospital(pickup.location.latitude, pickup.location.longitude);

      if (hospital != null && mounted) {
        setState(() {
          _dropPlace = hospital;
          _dropoffController.text = hospital.name;
        });
        await _displayRoute(pickup, hospital);
      } else {
        if (mounted) _showErrorSnackBar('Could not find any hospitals near your location.');
      }
    } catch (e) {
      print("Error in _findNearestHospitalAndRoute: $e");
      if (mounted) _showErrorSnackBar('Error finding hospital route: ${e.toString().substring(0, min(e.toString().length, 100))}');
    } finally {
      if(mounted) setState(() => _isLoading = false);
    }
  }

  Future<Place?> _findNearestHospital(double lat, double lng) async {
    // ATTEMPT 1: Geoapify (Primary)
    try {
      final url = 'https://api.geoapify.com/v2/places?categories=healthcare.hospital,healthcare.clinic,healthcare.doctors&filter=circle:$lng,$lat,25000&bias=proximity:$lng,$lat&limit=20&apiKey=$geoapifyApiKey';
      print("DEBUG: Geoapify Search URL: $url");
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      print("DEBUG: Geoapify Response Status: ${response.statusCode}");

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final features = decoded['features'] as List<dynamic>;
        print("DEBUG: Geoapify Found ${features.length} places.");
        if (features.isNotEmpty) {
          final props = features.first['properties'];
          print("DEBUG: Geoapify Closest: ${props['address_line1'] ?? props['name']}");
          final hLat = props['lat'];
          final hLon = props['lon'];
          if (hLat is num && hLon is num) {
            return Place(props['address_line1'] ?? props['name'] ?? 'Nearby Medical Facility', LatLng(hLat.toDouble(), hLon.toDouble()));
          }
        }
      } else {
        print("DEBUG: Geoapify Error Body: ${response.body}");
      }
    } catch (e) {
      print('Geoapify hospital search failed: $e');
    }

    // ATTEMPT 2: Nominatim (Fallback)
    try {
      if (mounted) _showInfoSnackBar('Primary search failed. Trying backup...');
      double searchRadiusDegrees = 0.25;
      double minLon = lng - searchRadiusDegrees;
      double minLat = lat - searchRadiusDegrees;
      double maxLon = lng + searchRadiusDegrees;
      double maxLat = lat + searchRadiusDegrees;
      final url = 'https://nominatim.openstreetmap.org/search?q=hospital&format=jsonv2&limit=20&viewbox=$minLon,$maxLat,$maxLon,$minLat&bounded=1';
      print("DEBUG: Nominatim Search URL: $url");
      final response = await http.get(Uri.parse(url), headers: {'User-Agent': 'com.example.patient_app'}).timeout(const Duration(seconds: 8));
      print("DEBUG: Nominatim Response Status: ${response.statusCode}");

      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List<dynamic>;
        print("DEBUG: Nominatim Found ${results.length} places.");
        if (results.isNotEmpty) {
          Place? closest;
          double? minDistance;
          for(var result in results) {
            if (result['lat'] != null && result['lon'] != null) {
              try {
                final placeLat = double.parse(result['lat']);
                final placeLon = double.parse(result['lon']);
                final place = Place(result['display_name'] ?? 'Unknown Hospital', LatLng(placeLat, placeLon));
                final distance = Geolocator.distanceBetween(lat, lng, place.location.latitude, place.location.longitude);
                if(minDistance == null || distance < minDistance) {
                  minDistance = distance;
                  closest = place;
                }
              } catch (parseError) {
                print("Error parsing Nominatim result: $parseError");
              }
            }
          }
          print("DEBUG: Nominatim Closest: ${closest?.name}");
          return closest;
        }
      } else {
        print("DEBUG: Nominatim Error Body: ${response.body}");
      }
    } catch (e) {
      print('Nominatim hospital search failed: $e');
    }

    return null; // Both searches failed
  }

  // --- Helper for showing SnackBars ---
  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
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

// --- Top-level helper function for checking permissions ---
Future<bool> _checkAndRequestLocationPermission(BuildContext context) async {
  bool serviceEnabled;
  LocationPermission permission;
  serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location services are disabled. Please enable them in settings.')));
    return false;
  }

  // --- *** THIS IS THE FIX *** ---
  permission = await Geolocator.checkPermission();
  // --- *** END OF FIX *** ---

  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions were denied.')));
      return false;
    }
  }
  if (permission == LocationPermission.deniedForever) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions are permanently denied.')));
    return false;
  }
  return true;
}