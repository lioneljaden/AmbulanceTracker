import 'dart:html';
import 'dart:js_interop';
import 'dart:async';
import 'package:js/js_util.dart' as js_util;
import 'package:socket_io_client/socket_io_client.dart' as IO;

// --- JS Interop (Corrected) ---
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
  external void setView(JSLatLng center, JSNumber zoom);
  external void addControl(JSObject control);
  external void invalidateSize();
}
@JS() @staticInterop class JSTileLayer {}
extension TileLayerExtension on JSTileLayer { external void addTo(JSMap map); }
@JS() @staticInterop class JSLatLng {}
@JS() @staticInterop class JSRouting {}
extension RoutingExtension on JSRouting { 
  external JSControl control(JSObject options); 
}
@JS() @staticInterop class JSControl {}
extension ControlExtension on JSControl { external void addTo(JSMap map); }

@JS() @staticInterop class JSIcon {}

@JS() @staticInterop class JSMarker {}
extension MarkerExtension on JSMarker { 
  external JSMarker addTo(JSMap map);
  external void setLatLng(JSLatLng latlng);
}


// --- Global State ---
IO.Socket? _socket;
JSMap? _map;
Timer? _locationBroadcastTimer;
Map<String, dynamic>? _currentRideDetails;
JSMarker? _driverMarker; // To show the driver's own location


void main() {
  _setupSocketConnection();
}

void _setupSocketConnection() {
  _socket = IO.io('http://localhost:3000', IO.OptionBuilder()
      .setTransports(['websocket'])
      .disableAutoConnect()
      .build());
  _socket!.connect();

  _socket!.onConnect((_) async {
    print('DEBUG: Driver connected to server: ${_socket!.id}');
    try {
      final pos = await window.navigator.geolocation.getCurrentPosition();
      final location = {
        'lat': pos.coords!.latitude,
        'lng': pos.coords!.longitude
      };
      _socket!.emit('driver-online', {'name': 'Real Driver', 'location': location});
      print('DEBUG: "driver-online" event emitted with location.');
    } catch (e) {
      print('ERROR: Could not get initial driver location. $e');
      _socket!.emit('driver-online', {'name': 'Real Driver'});
    }
  });

  _socket!.on('start-ride', (data) {
    print('DEBUG: "start-ride" event received!');
    _currentRideDetails = js_util.dartify(data) as Map<String, dynamic>;
    _startRide(_currentRideDetails!);
  });

   _socket!.onConnectError((data) => print('DEBUG: Connection Error: $data'));
   _socket!.onError((data) => print('DEBUG: Socket Error: $data'));
}

void _startRide(Map<String, dynamic> rideDetails) async {
  querySelector('#status-panel')?.innerHtml = '<h2>Ride in Progress</h2><p>Navigate to the pickup location.</p>';
  final mapContainer = querySelector('#map-container') as DivElement?;
  mapContainer?.style.display = 'block';
  querySelector('#finish-ride-btn')?.style.display = 'block';
  
  try {
    final driverPos = await window.navigator.geolocation.getCurrentPosition();
    final driverLat = driverPos.coords!.latitude!.toDouble();
    final driverLng = driverPos.coords!.longitude!.toDouble();

    _map = _l.map('map-container', <String, JSAny?>{
        'center': _l.latLng(driverLat.toJS, driverLng.toJS) as JSAny?,
        'zoom': 14.toJS
    }.toJSObject());

    _l.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', <String, JSAny?>{}.toJSObject()).addTo(_map!);
    
    await Future.delayed(Duration(milliseconds: 100));
    _map!.invalidateSize();

    final route = rideDetails['route'];
    final patientLocation = route['pickup'];
    
    final waypoints = [
      _l.latLng(driverLat.toJS, driverLng.toJS),
      _l.latLng((patientLocation['lat'] as num).toDouble().toJS, (patientLocation['lng'] as num).toDouble().toJS)
    ];

    // --- THE FIX: Use the 'createMarker' callback for a more robust solution ---
    final control = _l.Routing.control(<String, JSAny?>{
        'waypoints': (waypoints as List<JSAny?>).toJS,
        'routeWhileDragging': false.toJS,
        'createMarker': js_util.allowInterop((int i, JSAny waypoint, int n) {
            final latLng = js_util.getProperty(waypoint, 'latLng');

            // Waypoint 0 is the driver
            if (i == 0) {
                final ambulanceIcon = _l.icon(<String, JSAny?>{
                    'iconUrl': 'https://cdn-icons-png.flaticon.com/128/2929/2929339.png'.toJS,
                    'iconSize': [40.toJS, 40.toJS].toJS,
                    'iconAnchor': [20.toJS, 40.toJS].toJS,
                }.toJSObject());
                // Create the driver marker and save the reference so we can move it.
                _driverMarker = _l.marker(latLng as JSLatLng, <String, JSAny?>{'icon': ambulanceIcon as JSAny?}.toJSObject());
                return _driverMarker;
            }
            
            // The other waypoint is the patient
            final patientIcon = _l.icon(<String, JSAny?>{
                'iconUrl': 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png'.toJS,
                'iconSize': [25.toJS, 41.toJS].toJS,
                'iconAnchor': [12.toJS, 41.toJS].toJS,
            }.toJSObject());
            return _l.marker(latLng as JSLatLng, <String, JSAny?>{'icon': patientIcon as JSAny?}.toJSObject());
        }) as JSAny?
    }.toJSObject());
    
    (control as JSControl).addTo(_map!);

    // Start broadcasting location to move the marker and update the patient
    _locationBroadcastTimer?.cancel();
    _locationBroadcastTimer = Timer.periodic(Duration(seconds: 3), (timer) async {
        try {
            final pos = await window.navigator.geolocation.getCurrentPosition();
            final newLatLng = _l.latLng(pos.coords!.latitude!.toJS, pos.coords!.longitude!.toJS);
            
            // This now moves the marker created by the routing control
            _driverMarker?.setLatLng(newLatLng);

            // Send the update to the server for the patient to see
            _socket?.emit('driver-location-update', {
                'lat': pos.coords!.latitude,
                'lng': pos.coords!.longitude
            });
        } catch (e) {
            print('Could not get driver location for broadcast');
        }
    });

    querySelector('#finish-ride-btn')?.onClick.listen((_) {
        _locationBroadcastTimer?.cancel();
         window.navigator.geolocation.getCurrentPosition().then((pos) {
            _socket?.emit('ride-finished', {
              'location': {'lat': pos.coords!.latitude, 'lng': pos.coords!.longitude}
            });
         });
        
        final statusPanel = querySelector('#status-panel') as DivElement?;
        statusPanel?.innerHtml = '<h2>Waiting for requests...</h2><p>You are online and available.</p>';
        mapContainer?.style.display = 'none';
        querySelector('#finish-ride-btn')?.style.display = 'none';
    });

  } catch (e) {
      window.alert('Could not get driver location to start ride.');
  }
}

