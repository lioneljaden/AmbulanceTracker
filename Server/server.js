// This server is the central hub connecting patients and drivers.
const express = require('express');
const http = require('http');
const { Server } = require("socket.io");

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*", // Allow all origins for simplicity
    methods: ["GET", "POST"]
  }
});

// --- In-memory state management ---
// FIX: Use a SINGLE object to store all driver data and status
let drivers = {}; // Key: socket.id, Value: { id, name, location, status, route, driverState }
let activeRides = {}; // Maps patientId to ride details

// --- Helper Functions ---
function getDistanceFromLatLonInKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = deg2rad(lat2 - lat1);
  const dLon = deg2rad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(deg2rad(lat1)) * Math.cos(deg2rad(lat2)) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}
function deg2rad(deg) { return deg * (Math.PI / 180); }


// --- Socket.IO Connection Logic ---
io.on('connection', (socket) => {
  console.log('A user connected:', socket.id);

  // --- NEW: Dashboard Connection ---
  socket.on('dashboard-online', () => {
    console.log(`Dashboard connected: ${socket.id}`);
    socket.join('dashboards'); // Add this socket to the 'dashboards' room
    
    // Send a complete snapshot of the current fleet status
    const fleetStatus = Object.values(drivers);
    socket.emit('fleet-snapshot', fleetStatus);
  });

  // --- Driver Connection ---
  socket.on('driver-online', (driverData) => {
    console.log('A real driver has come online:', socket.id);
    
    // FIX: Add driver to the single 'drivers' object
    const driver = {
      id: socket.id,
      status: 'available', // 'available', 'on-ride'
      route: [], // --- NEW: Add route property
      driverState: 'DriverState.waiting', // --- NEW: Add driverState
      ...driverData
    };
    drivers[socket.id] = driver;
    
    // Notify all dashboards of the new driver
    io.to('dashboards').emit('driver-update', driver);
    console.log('Available drivers:', Object.keys(drivers).length);
  });

  // --- Patient Booking ---
  socket.on('request-booking', (data) => {
    const { route, patientId } = data; 
    const patientSocketId = socket.id;
    
    if (!patientId || !route?.pickup?.lat || !route?.pickup?.lng) {
      return console.error("Invalid booking request data received.");
    }

    console.log(`New booking request from patient ID: ${patientId}`);
    const pickupLocation = route.pickup;

    // FIX: Find available drivers from the single 'drivers' object
    const availableDrivers = Object.values(drivers).filter(d => d.status === 'available' && d.location);

    if (availableDrivers.length > 0) {
      let closestDriver = availableDrivers.reduce((prev, curr) => {
        const prevDistance = getDistanceFromLatLonInKm(pickupLocation.lat, pickupLocation.lng, prev.location.lat, prev.location.lng);
        const currDistance = getDistanceFromLatLonInKm(pickupLocation.lat, pickupLocation.lng, curr.location.lat, curr.location.lng);
        return (prevDistance < currDistance) ? prev : curr;
      });
      
      // Set driver to "on-ride" in the single 'drivers' object
      drivers[closestDriver.id].status = 'on-ride';
      
      const rideDetails = { 
        patientSocketId: patientSocketId, 
        driverId: closestDriver.id, 
        route: route, 
        status: 'active' 
      };
      activeRides[patientId] = rideDetails; 
      
      const driverInfo = { driverName: closestDriver.name, vehicle: closestDriver.vehicle, driverLocation: closestDriver.location };
      
      console.log(`Assigning ride to REAL driver ${closestDriver.id}.`);
      
      // These 3 emits will now work correctly
      io.to(patientSocketId).emit('booking-accepted', driverInfo);
      io.to(closestDriver.id).emit('start-ride', rideDetails);
      io.to('dashboards').emit('driver-update', drivers[closestDriver.id]);
      
    } else {
      console.log('No drivers available for patient:', patientId);
      io.to(patientSocketId).emit('no-drivers-available');
    }
  });

  // --- Ride Management Events ---
  socket.on('cancel-ride', (data) => {
    const ride = activeRides[data.patientId];
    if (ride) {
        console.log(`Cancelling ride. Notifying driver ${ride.driverId}`);
        io.to(ride.driverId).emit('ride-canceled');
        
        // Make driver available again
        if (drivers[ride.driverId]) {
            drivers[ride.driverId].status = 'available';
            // --- MODIFIED: Clear route and state on cancel ---
            drivers[ride.driverId].route = [];
            drivers[ride.driverId].driverState = 'DriverState.waiting';
            io.to('dashboards').emit('driver-update', drivers[ride.driverId]);
            // Also tell dashboard to clear the route visualization
            io.to('dashboards').emit('fleet-route-update', { 
                driverId: ride.driverId, 
                route: [], 
                driverState: 'DriverState.waiting' 
            });
        }
        delete activeRides[data.patientId];
    }
  });

  socket.on('driver-picked-up-patient', (data) => {
      const patientId = data.patientId;
      if (patientId && activeRides[patientId]) {
          io.to(activeRides[patientId].patientSocketId).emit('en-route-to-hospital');
      }
  });

  socket.on('driver-location-update', (data) => {
      const patientId = Object.keys(activeRides).find(pId => activeRides[pId].driverId === socket.id);
      if (patientId) {
          io.to(activeRides[patientId].patientSocketId).emit('ambulance-location-update', { lat: data.lat, lng: data.lng });
      }
      
      // Update driver's location in our main list
      if (drivers[socket.id]) {
          drivers[socket.id].location = data;
          // Broadcast live location to all dashboards
          io.to('dashboards').emit('fleet-location-update', { driverId: socket.id, location: data });
      }
  });
  
  // --- Listen for route updates from the driver ---
  socket.on('driver-route-update', (data) => {
      if (drivers[socket.id]) {
          drivers[socket.id].route = data.route;
          drivers[socket.id].driverState = data.driverState;
          
          // Broadcast this new route to all dashboards
          io.to('dashboards').emit('fleet-route-update', {
              driverId: socket.id,
              route: data.route,
              driverState: data.driverState
          });

          // --- *** THIS IS THE CHANGE (Part 2) *** ---
          // Find the patient associated with this driver and send them the route
          const patientId = Object.keys(activeRides).find(pId => activeRides[pId].driverId === socket.id);
          if (patientId) {
              io.to(activeRides[patientId].patientSocketId).emit('ambulance-route-update', data);
              console.log(`Sent route update to patient ${patientId}`);
          }
          // --- *** END OF CHANGE *** ---
      }
  });
  // --- END NEW ---

  socket.on('ride-finished', (data) => {
      const patientId = Object.keys(activeRides).find(pId => activeRides[pId].driverId === socket.id);
      if (patientId) {
          console.log(`Ride finished for patient ${patientId}`);
          io.to(activeRides[patientId].patientSocketId).emit('ride-finished');
          
          // Make driver available again
          if (drivers[socket.id]) {
              drivers[socket.id].status = 'available';
              drivers[socket.id].location = data.location;
              // --- MODIFIED: Clear route and state on finish ---
              drivers[socket.id].route = [];
              drivers[socket.id].driverState = 'DriverState.waiting';
              io.to('dashboards').emit('driver-update', drivers[socket.id]);
              
              // --- NEW: Also tell dashboard to clear the route visualization ---
              io.to('dashboards').emit('fleet-route-update', { 
                driverId: socket.id, 
                route: [], 
                driverState: 'DriverState.waiting' 
              });
          }
          delete activeRides[patientId];
      }
  });

  socket.on('disconnect', () => {
    console.log('User disconnected:', socket.id);
    
    // Check if it was a driver
    if (drivers[socket.id]) {
        console.log(`Driver ${socket.id} disconnected.`);
        io.to('dashboards').emit('driver-disconnected', { driverId: socket.id });
        delete drivers[socket.id];
    }

    // Check if it was a patient on a ride
    const patientId = Object.keys(activeRides).find(pId => activeRides[pId].patientSocketId === socket.id);
    if (patientId) {
       console.log(`Patient ${patientId} (socket ${socket.id}) disconnected.`);
       // Note: We could auto-cancel the ride here, but for now we leave it.
    }
  });
});


const PORT = 3000;
server.listen(PORT, () => {
  console.log(`Server is running on port ${PORT}`);
  console.log('Waiting for real drivers, patients, and dashboards to connect...');
});