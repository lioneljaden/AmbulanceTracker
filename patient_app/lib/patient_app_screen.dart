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
// IMPORTANT: Replace with your PC's local IP address to test on a physical device.
// Use 'http://10.0.2.2:3000' for the Android emulator.
const serverUrl = 'http://10.0.2.2:3000';


// --- Data Models ---
class Place {
  final String name;
  final LatLng location;
  Place(this.name, this.location);
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

  List<LatLng> _routePoints = [];
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

  @override
  void initState() {
    super.initState();
    _setupSocketConnection();
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
    _socket = IO.io(serverUrl, IO.OptionBuilder()
        .setTransports(['websocket']).disableAutoConnect().build());
    _socket!.connect();
    _socket!.onConnect((_) => print('Connected to server: ${_socket!.id}'));
    _socket!.on('booking-accepted', (data) {
      if (mounted) setState(() {
        _currentState = AppState.status;
        _driverInfo = 'Driver: ${data['driverName']} | Vehicle: ${data['vehicle']}';
        _addAmbulanceMarker(_pickupPlace!.location);
      });
    });
    _socket!.on('ambulance-location-update', (data) {
      if (mounted) _addAmbulanceMarker(LatLng(data['lat'], data['lng']));
    });
    _socket!.on('ride-finished', (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You have arrived!')));
      _resetToBooking();
    });
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
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.patient_app',
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(polylines: [Polyline(points: _routePoints, color: Colors.black, strokeWidth: 5)]),
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
              onPressed: _showEmergencyModal,
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
      ],
    );
  }

  // --- Logic Methods ---
  Future<void> _handleFindRoute() async {
    if (_pickupPlace == null || _dropPlace == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a pickup and drop-off location.')));
      return;
    }
    _displayRoute(_pickupPlace!, _dropPlace!);
  }

  Future<void> _displayRoute(Place start, Place end) async {
    final url = 'https://api.geoapify.com/v1/routing?waypoints=${start.location.latitude},${start.location.longitude}|${end.location.latitude},${end.location.longitude}&mode=drive&apiKey=$geoapifyApiKey';
    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 200 && mounted) {
      final decoded = jsonDecode(response.body);
      final geometry = decoded['features'][0]['geometry']['coordinates'][0];
      final points = geometry.map<LatLng>((p) => LatLng(p[1], p[0])).toList();
      final eta = decoded['features'][0]['properties']['time'] / 60;

      if (points.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not find a valid route.')));
        return;
      }

      setState(() {
        _routePoints = points;
        _markers = [
          Marker(point: start.location, child: const Icon(Icons.person_pin_circle, color: Colors.blue, size: 40)),
          Marker(point: end.location, child: const Icon(Icons.local_hospital, color: Colors.red, size: 40)),
        ];
        _etaMessage = 'Estimated Time: ${eta.ceil()} mins';
        _currentState = AppState.confirmation;
      });
      _mapController.fitCamera(CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(150)));
    } else {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error calculating route. Please try again.')));
    }
  }

  void _handleConfirmBooking() {
    final route = SimpleRoute(_pickupPlace!, _dropPlace!);
    _socket?.emit('request-booking', route.toJson());
    setState(() { _etaMessage = "Searching for nearby drivers..."; });
  }

  void _resetToBooking() {
    setState(() {
      _routePoints = [];
      _markers = [];
      _ambulanceMarker = null;
      _currentState = AppState.booking;
      _pickupController.clear();
      _dropoffController.clear();
      _pickupSuggestions.clear();
      _dropSuggestions.clear();
      _activeInputField = null;
    });
    _mapController.move(LatLng(12.9141, 74.8560), 13);
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
  Widget _buildAutocompleteSection({
    required TextEditingController controller,
    required String hint,
    required List<Place> suggestions,
    required Function(Place) onSelect,
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
          ),
          onTap: () => setState(() => _activeInputField = fieldType),
          onChanged: (text) {
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
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200 && mounted) {
      final features = jsonDecode(response.body)['features'] as List<dynamic>;
      final places = features.map((f) {
        final props = f['properties'];
        return Place(props['formatted'], LatLng(props['lat'], props['lon']));
      }).toList();
      setState(() {
        if (fieldType == "pickup") _pickupSuggestions = places;
        else _dropSuggestions = places;
      });
    }
  }

  // --- EMERGENCY MODAL LOGIC ---
  Future<void> _showEmergencyModal() async {
    final result = await showDialog<Place>(
      context: context,
      builder: (context) => const EmergencyModal(),
    );

    if (result != null) {
      await _findNearestHospitalAndRoute(result);
    }
  }

  Future<void> _findNearestHospitalAndRoute(Place pickup) async {
    setState(() {
      _isLoading = true;
      _pickupPlace = pickup;
    });

    try {
      final hospital = await _findNearestHospital(pickup.location.latitude, pickup.location.longitude);
      if (hospital != null && mounted) {
        setState(() => _dropPlace = hospital);
        _displayRoute(pickup, hospital);
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not find any hospitals near your location.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error finding hospital route: $e')));
    } finally {
      if(mounted) setState(() => _isLoading = false);
    }
  }

  Future<Place?> _findNearestHospital(double lat, double lng) async {
    // ATTEMPT 1: Geoapify (Primary)
    try {
      final url = 'https://api.geoapify.com/v2/places?categories=healthcare.hospital,healthcare.clinic&filter=circle:$lng,$lat,25000&bias=proximity:$lng,$lat&limit=20&apiKey=$geoapifyApiKey';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 7));
      if (response.statusCode == 200) {
        final features = jsonDecode(response.body)['features'] as List<dynamic>;
        if (features.isNotEmpty) {
          final props = features.first['properties'];
          return Place(props['address_line1'] ?? 'Nearby Hospital', LatLng(props['lat'], props['lon']));
        }
      }
    } catch (e) {
      print('Geoapify hospital search failed: $e');
    }

    // ATTEMPT 2: Nominatim (Fallback)
    try {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Primary search failed. Trying backup...'), duration: Duration(seconds: 1)));
      final url = 'https://nominatim.openstreetmap.org/search?q=hospital&format=jsonv2&limit=20&viewbox=${lng-0.2},${lat+0.2},${lng+0.2},${lat-0.2}&bounded=1';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 7));
      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List<dynamic>;
        if (results.isNotEmpty) {
          Place? closest;
          double? minDistance;
          for(var result in results) {
            final place = Place(result['display_name'], LatLng(double.parse(result['lat']), double.parse(result['lon'])));
            final distance = Geolocator.distanceBetween(lat, lng, place.location.latitude, place.location.longitude);
            if(minDistance == null || distance < minDistance) {
              minDistance = distance;
              closest = place;
            }
          }
          return closest;
        }
      }
    } catch (e) {
      print('Nominatim hospital search failed: $e');
    }

    return null; // Both searches failed
  }
}

// --- DEDICATED WIDGET FOR THE EMERGENCY MODAL ---
class EmergencyModal extends StatefulWidget {
  const EmergencyModal({Key? key}) : super(key: key);

  @override
  _EmergencyModalState createState() => _EmergencyModalState();
}

class _EmergencyModalState extends State<EmergencyModal> {
  final _controller = TextEditingController();
  List<Place> _suggestions = [];
  Place? _selectedPlace;
  Timer? _debounce;
  bool _isLoadingLocation = false;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _fetchAutocomplete(String text) async {
    final url = 'https://api.geoapify.com/v1/geocode/autocomplete?text=${Uri.encodeComponent(text)}&apiKey=$geoapifyApiKey';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200 && mounted) {
      final features = jsonDecode(response.body)['features'] as List<dynamic>;
      setState(() {
        _suggestions = features.map((f) {
          final props = f['properties'];
          return Place(props['formatted'], LatLng(props['lat'], props['lon']));
        }).toList();
      });
    }
  }

  Future<void> _handleUseCurrentLocation() async {
    setState(() => _isLoadingLocation = true);
    final hasPermission = await _checkLocationPermission(context);
    if (!hasPermission) {
      setState(() => _isLoadingLocation = false);
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final place = Place('Current Location', LatLng(position.latitude, position.longitude));
      if (mounted) Navigator.of(context).pop(place);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not get current location.')));
      setState(() => _isLoadingLocation = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Emergency Pickup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            decoration: const InputDecoration(hintText: 'Enter pickup address...'),
            onChanged: (text) {
              if (_debounce?.isActive ?? false) _debounce!.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () {
                if (text.length > 2) _fetchAutocomplete(text);
              });
            },
          ),
          if (_suggestions.isNotEmpty)
            SizedBox(
              height: 100,
              width: double.maxFinite,
              child: ListView.builder(
                itemCount: _suggestions.length,
                itemBuilder: (context, index) {
                  final place = _suggestions[index];
                  return ListTile(
                    title: Text(place.name, style: const TextStyle(fontSize: 14)),
                    onTap: () {
                      setState(() {
                        _controller.text = place.name;
                        _selectedPlace = place;
                        _suggestions.clear();
                      });
                    },
                  );
                },
              ),
            ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () {
              if (_selectedPlace != null) {
                Navigator.of(context).pop(_selectedPlace);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select an address.')));
              }
            },
            child: const Text('Find Nearest Hospital'),
          ),
          const SizedBox(height: 10),
          _isLoadingLocation
              ? const CircularProgressIndicator()
              : TextButton(
            onPressed: _handleUseCurrentLocation,
            child: const Text('Use My Current Location'),
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

// --- Top-level helper function for checking permissions ---
Future<bool> _checkLocationPermission(BuildContext context) async {
  bool serviceEnabled;
  LocationPermission permission;
  serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location services are disabled.')));
    return false;
  }
  permission = await Geolocator.checkPermission();
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

