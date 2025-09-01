// This file contains all the logic for the Patient's view.
// It handles a standard pickup/drop-off flow and an emergency modal flow.

import 'dart:html';
import 'dart:js_interop';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:js/js_util.dart' as js_util;
import 'package:socket_io_client/socket_io_client.dart' as IO;


// --- CONFIGURATION ---
const geoapifyApiKey = '1184478395cc4017a33a122f110602b7';


// --- Data Classes ---
class Place {
  final String name;
  final double latitude;
  final double longitude;
  Place(this.name, this.latitude, this.longitude);
}

// --- JS Interop Definitions ---
extension on Map<String, JSAny?> { JSObject toJSObject() { final obj = js_util.newObject<JSObject>(); forEach((key, value) { js_util.setProperty(obj, key, value); }); return obj; } }
@JS('L') external JSObject get _l;
extension LExtension on JSObject {
  JSMap map(String id, JSObject options) => js_util.callMethod(this, 'map', [id.toJS, options]) as JSMap;
  JSTileLayer tileLayer(String url, JSObject options) => js_util.callMethod(this, 'tileLayer', [url.toJS, options]) as JSTileLayer;
  JSLatLng latLng(JSNumber lat, JSNumber lng) => js_util.callMethod(this, 'latLng', [lat, lng]) as JSLatLng;
  JSRouting get Routing => js_util.getProperty(this, 'Routing');
  JSIcon icon(JSObject options) => js_util.callMethod(this, 'icon', [options]) as JSIcon;
  JSMarker marker(JSLatLng latlng, JSObject options) => js_util.callMethod(this, 'marker', [latlng, options]) as JSMarker;
}
@JS() @staticInterop class JSMap {}
extension MapExtension on JSMap {
  external JSMap setView(JSLatLng center, JSNumber zoom);
  external void addControl(JSObject control);
  external void removeControl(JSObject control);
  external void addLayer(JSObject layer);
  external void removeLayer(JSObject layer);
  external void invalidateSize();
}
@JS() @staticInterop class JSTileLayer {}
extension TileLayerExtension on JSTileLayer { external void addTo(JSMap map); }
@JS() @staticInterop class JSLatLng {}
extension JSLatLngExtension on JSLatLng {
    external JSNumber get lat;
    external JSNumber get lng;
}
@JS() @staticInterop class JSRouting {}
extension RoutingExtension on JSRouting { external JSControl control(JSObject options); } 
@JS() @staticInterop class JSIcon {}
@JS() @staticInterop class JSMarker {}
extension MarkerExtension on JSMarker {
    external JSMarker setLatLng(JSLatLng latlng);
    external JSMarker addTo(JSMap map);
}
@JS() @staticInterop class JSControl {}
extension ControlExtension on JSControl {
    external void addTo(JSMap map);
    external JSControl on(JSString event, JSFunction callback);
}


// --- Global State ---
Place? _pickupPlace;
Place? _dropPlace;
Timer? _pickupDebounce;
Timer? _dropDebounce;
Timer? _emergencyDebounce;
JSMap? _map;
JSControl? _currentRoutingControl;
JSMarker? _ambulanceMarker;
IO.Socket? _socket;
JSObject? _currentRoute;


// --- Main Initialization Function ---
void initialize() {
  _initializeMap();
  _setupSocketConnection();
  _setupStandardListeners();
  _setupEmergencyListeners();
  _setupBookingConfirmationListeners();
}

void _initializeMap() {
    _map = _l.map('map', <String, JSAny?>{'center': _l.latLng(12.9141.toJS, 74.8560.toJS) as JSAny?, 'zoom': 13.toJS, 'zoomControl': false.toJS}.toJSObject());
    _l.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', <String, JSAny?>{
        'attribution': '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'.toJS,
    }.toJSObject()).addTo(_map!);
    Future.delayed(Duration(milliseconds: 200), () => _map?.invalidateSize());
}

void _setupSocketConnection() {
    _socket = IO.io('http://localhost:3000', IO.OptionBuilder()
        .setTransports(['websocket']) 
        .disableAutoConnect()
        .build());
    _socket!.connect();

    _socket!.onConnect((_) => print('Connected to server with ID: ${_socket!.id}'));

    _socket!.on('booking-accepted', (data) {
        querySelector('#confirmation-panel')?.style.display = 'none';
        final statusPanel = querySelector('#status-panel') as DivElement?;
        final driverInfo = querySelector('#driver-info') as ParagraphElement?;
        statusPanel?.style.display = 'block';
        driverInfo?.text = 'Driver: ${data['driverName']} | Vehicle: ${data['vehicle']}';
        _createOrUpdateAmbulanceMarker(_pickupPlace!.latitude, _pickupPlace!.longitude);
    });

    _socket!.on('ambulance-location-update', (data) {
        _createOrUpdateAmbulanceMarker(data['lat'], data['lng']);
    });

    _socket!.on('ride-finished', (_) {
        window.alert('You have arrived at your destination!');
        _resetToBooking();
    });
}

void _setupStandardListeners() {
    final pickupInput = querySelector('#pickup-input') as InputElement?;
    final dropInput = querySelector('#drop-input') as InputElement?;
    final findRouteBtn = querySelector('#find-route-btn') as ButtonElement?;
    final backBtn = querySelector('#back-to-booking-btn') as ButtonElement?;

    pickupInput?.onInput.listen((_) {
        _pickupPlace = null;
        if (_pickupDebounce?.isActive ?? false) _pickupDebounce!.cancel();
        _pickupDebounce = Timer(const Duration(milliseconds: 300), () => _handleAutocomplete(pickupInput, '#pickup-autocomplete', (place) => _pickupPlace = place));
    });

    dropInput?.onInput.listen((_) {
        _dropPlace = null;
        if (_dropDebounce?.isActive ?? false) _dropDebounce!.cancel();
        _dropDebounce = Timer(const Duration(milliseconds: 300), () => _handleAutocomplete(dropInput, '#drop-autocomplete', (place) => _dropPlace = place));
    });

    findRouteBtn?.onClick.listen((_) {
        if (_pickupPlace != null && _dropPlace != null) {
            _displayRoute(_pickupPlace!, _dropPlace!);
        } else {
            window.alert('Please select a valid pickup and drop-off location from the suggestions.');
        }
    });
    
    backBtn?.onClick.listen((_) => _resetToBooking());
}

void _setupEmergencyListeners() {
    final emergencyBtn = querySelector('#emergency-btn');
    final modalOverlay = querySelector('#emergency-modal-overlay') as DivElement?;
    final closeModalBtn = querySelector('#close-modal-btn');
    final emergencyAddressInput = querySelector('#emergency-address-input') as InputElement?;
    final emergencyCurrentLocationBtn = querySelector('#emergency-current-location-btn');
    final emergencyBookBtn = querySelector('#emergency-book-btn');

    emergencyBtn?.onClick.listen((_) => modalOverlay?.style.display = 'flex');
    closeModalBtn?.onClick.listen((_) => modalOverlay?.style.display = 'none');

    emergencyAddressInput?.onInput.listen((_) {
        _pickupPlace = null; 
        if (_emergencyDebounce?.isActive ?? false) _emergencyDebounce!.cancel();
        _emergencyDebounce = Timer(const Duration(milliseconds: 300), () => _handleAutocomplete(emergencyAddressInput, '#emergency-autocomplete-results', (place) => _pickupPlace = place));
    });

    emergencyCurrentLocationBtn?.onClick.listen((_) async {
        try {
            final position = await window.navigator.geolocation.getCurrentPosition();
            _pickupPlace = Place('Current Location', position.coords!.latitude!.toDouble(), position.coords!.longitude!.toDouble());
            _findNearestHospitalAndRoute(_pickupPlace!);
            modalOverlay?.style.display = 'none';
        } catch (e) { window.alert('Could not get current location.'); }
    });

    emergencyBookBtn?.onClick.listen((_) {
        if (_pickupPlace != null) {
            _findNearestHospitalAndRoute(_pickupPlace!);
            modalOverlay?.style.display = 'none';
        } else { window.alert('Please select a pickup location.'); }
    });
}

void _setupBookingConfirmationListeners() {
    // We need to query for the buttons again because they might be rebuilt.
    final confirmBtn = querySelector('#confirm-booking-btn');
    final cancelBtn = querySelector('#cancel-booking-btn');
    final cancelRideBtn = querySelector('#cancel-ride-btn');

    confirmBtn?.onClick.listen((_) {
        if (_currentRoute != null) {
            _socket?.emit('request-booking', {'route': js_util.dartify(_currentRoute!)});
            (querySelector('#confirmation-panel') as DivElement?)?.innerHtml = '<p>Searching for nearby drivers...</p><div class="loader"></div>';
        }
    });

    cancelBtn?.onClick.listen((_) => _resetToBooking());
    cancelRideBtn?.onClick.listen((_) {
        _socket?.emit('cancel-booking');
        _resetToBooking();
    });
}


// --- Autocomplete Logic ---
void _handleAutocomplete(InputElement? input, String resultsSelector, Function(Place) onSelect) {
    final text = input?.value?.trim();
    if (text != null && text.length > 2) {
        _fetchAutocompleteSuggestions(input, text, resultsSelector, onSelect);
    } else {
        (querySelector(resultsSelector) as DivElement?)?.innerHtml = '';
    }
}

Future<void> _fetchAutocompleteSuggestions(InputElement? input, String text, String resultsSelector, Function(Place) onSelect) async {
    final resultsContainer = querySelector(resultsSelector) as DivElement?;
    try {
        final url = 'https://api.geoapify.com/v1/geocode/autocomplete?text=${Uri.encodeComponent(text)}&apiKey=$geoapifyApiKey';
        final response = await HttpRequest.request(url);
        final results = jsonDecode(response.responseText!)['features'] as List<dynamic>;
        
        resultsContainer?.innerHtml = '';
        for (final feature in results) {
            final properties = feature['properties'];
            final place = Place(properties['formatted'], properties['lat'], properties['lon']);
            resultsContainer?.append(DivElement()
                ..text = place.name
                ..onClick.listen((_) {
                    input?.value = place.name;
                    onSelect(place);
                    resultsContainer.innerHtml = '';
                }));
        }
    } catch(e) { print('Autocomplete fetch error: $e'); }
}


// --- Routing and Map Display ---
Future<void> _findNearestHospitalAndRoute(Place pickup) async {
    try {
        final hospital = await _findNearestHospital(pickup.latitude, pickup.longitude);
        if (hospital != null) {
            _dropPlace = hospital;
            _displayRoute(pickup, hospital);
        } else {
            window.alert('Could not find any hospitals near the selected location.');
        }
    } catch (e) { window.alert('Error finding hospital route.'); }
}

Future<Place?> _findNearestHospital(double lat, double lng) async {
    final url = 'https://api.geoapify.com/v2/places?categories=healthcare.hospital&filter=circle:$lng,$lat,25000&bias=proximity:$lng,$lat&limit=1&apiKey=$geoapifyApiKey';
    try {
        final response = await HttpRequest.request(url);
        final features = jsonDecode(response.responseText!)['features'] as List<dynamic>;
        if (features.isNotEmpty) {
            final props = features.first['properties'];
            return Place(props['address_line1'] ?? 'Nearby Hospital', props['lat'], props['lon']);
        }
    } catch (e) { print('Geoapify hospital search failed.'); }
    return null;
}

void _displayRoute(Place start, Place end) {
    if (_currentRoutingControl != null) {
        _map?.removeControl(_currentRoutingControl! as JSObject);
    }
    
    final waypoints = [_l.latLng(start.latitude.toJS, start.longitude.toJS), _l.latLng(end.latitude.toJS, end.longitude.toJS)];
    
    _currentRoutingControl = _l.Routing.control(<String, JSAny?>{
        'waypoints': (waypoints as List<JSAny?>).toJS,
        'createMarker': js_util.allowInterop((int i, JSAny wp, int n) => false.toJS) as JSAny?,
        'show': false.toJS,
        'addWaypoints': false.toJS,
        'fitSelectedRoutes': true.toJS,
        'routeWhileDragging': false.toJS
    }.toJSObject());

    _currentRoutingControl!.on('routesfound'.toJS, js_util.allowInterop((e) {
        final routes = js_util.getProperty(e, 'routes') as JSArray;
        if (routes.length > 0) {
            final route = js_util.getProperty(routes, 0);
            _currentRoute = route;
            final summary = js_util.getProperty(route, 'summary');
            final totalTime = js_util.getProperty(summary, 'totalTime');
            final eta = (totalTime as JSNumber).toDartDouble / 60;

            final etaInfo = querySelector('#eta-info') as ParagraphElement?;
            etaInfo?.text = 'Estimated Time: ${eta.ceil()} mins';
            
            (querySelector('.booking-panel') as DivElement?)?.style.display = 'none';
            (querySelector('#confirmation-panel') as DivElement?)?.style.display = 'block';
            (querySelector('#back-to-booking-btn') as ButtonElement?)?.style.display = 'block';
        }
    }) as JSFunction);

    (_currentRoutingControl as JSControl).addTo(_map!);
    
    final userIcon = _l.icon(<String, JSAny?>{'iconUrl': 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png'.toJS, 'iconSize': [25.toJS, 41.toJS].toJS, 'iconAnchor': [12.toJS, 41.toJS].toJS}.toJSObject());
    final hospitalIcon = _l.icon(<String, JSAny?>{'iconUrl': 'https://cdn-icons-png.flaticon.com/128/3303/3303895.png'.toJS, 'iconSize': [40.toJS, 40.toJS].toJS, 'iconAnchor': [20.toJS, 40.toJS].toJS}.toJSObject());
    _l.marker(_l.latLng(start.latitude.toJS, start.longitude.toJS), <String, JSAny?>{'icon': userIcon as JSAny?}.toJSObject()).addTo(_map!);
    _l.marker(_l.latLng(end.latitude.toJS, end.longitude.toJS), <String, JSAny?>{'icon': hospitalIcon as JSAny?}.toJSObject()).addTo(_map!);
}

// --- UI Reset and State Management ---

void _resetToBooking() {
    (querySelector('.booking-panel') as DivElement?)?.style.display = 'block';
    (querySelector('#confirmation-panel') as DivElement?)?.style.display = 'none';
    (querySelector('#status-panel') as DivElement?)?.style.display = 'none';
    (querySelector('#back-to-booking-btn') as ButtonElement?)?.style.display = 'none';
    (querySelector('#pickup-input') as InputElement?)?.value = '';
    (querySelector('#drop-input') as InputElement?)?.value = '';

    final confirmationPanel = querySelector('#confirmation-panel') as DivElement?;
    confirmationPanel?.innerHtml = '''
        <h3>Confirm Booking</h3>
        <p id="eta-info">Calculating ETA...</p>
        <button id="confirm-booking-btn">Confirm Booking</button>
        <button id="cancel-booking-btn" style="background-color: var(--dark-grey); margin-top: 10px;">Cancel</button>
    ''';
    _setupBookingConfirmationListeners();

    if (_currentRoutingControl != null) {
        _map?.removeControl(_currentRoutingControl! as JSObject);
        _currentRoutingControl = null;
    }
    if (_ambulanceMarker != null) {
        _map?.removeLayer(_ambulanceMarker! as JSObject);
        _ambulanceMarker = null;
    }
    _initializeMap();
}

void _createOrUpdateAmbulanceMarker(double lat, double lng) {
    final ambulanceIcon = _l.icon(<String, JSAny?>{
        'iconUrl': 'https://cdn-icons-png.flaticon.com/128/2929/2929339.png'.toJS,
        'iconSize': [40.toJS, 40.toJS].toJS,
        'iconAnchor': [20.toJS, 40.toJS].toJS,
    }.toJSObject());

    if (_ambulanceMarker == null) {
        _ambulanceMarker = _l.marker(_l.latLng(lat.toJS, lng.toJS), <String, JSAny?>{'icon': ambulanceIcon as JSAny?}.toJSObject());
        _ambulanceMarker!.addTo(_map!);
    } else {
        _ambulanceMarker!.setLatLng(_l.latLng(lat.toJS, lng.toJS));
    }
}

