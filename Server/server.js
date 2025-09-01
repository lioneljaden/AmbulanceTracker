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
let availableDrivers = []; // Pool of real drivers waiting for a ride
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

  socket.on('driver-online', (driverData) => {
    console.log('A real driver has come online:', socket.id);
    const existingDriverIndex = availableDrivers.findIndex(d => d.id === socket.id);
    if (existingDriverIndex > -1) {
      availableDrivers[existingDriverIndex].location = driverData.location;
    } else {
      // Only add drivers if they have provided a location
      if(driverData.location) {
        availableDrivers.push({ id: socket.id, ...driverData });
      }
    }
    console.log('Available drivers:', availableDrivers.map(d => d.id));
  });

  socket.on('request-booking', (data) => {
    console.log('New booking request from patient:', socket.id);
    const pickupLocation = data.pickup;

    if (!pickupLocation || !pickupLocation.lat || !pickupLocation.lng) {
      console.error("Invalid pickup location data received.");
      return;
    }

    // Find the closest driver from the pool of REAL drivers
    const driversWithLocation = availableDrivers.filter(d => d.location);

    if (driversWithLocation.length > 0) {
      let closestDriver = driversWithLocation.reduce((prev, curr) => {
        const prevDistance = getDistanceFromLatLonInKm(pickupLocation.lat, pickupLocation.lng, prev.location.lat, prev.location.lng);
        const currDistance = getDistanceFromLatLonInKm(pickupLocation.lat, pickupLocation.lng, curr.location.lat, curr.location.lng);
        return (prevDistance < currDistance) ? prev : curr;
      });
      
      // Remove the chosen driver from the available pool
      availableDrivers = availableDrivers.filter(driver => driver.id !== closestDriver.id);
      
      const rideDetails = { patientId: socket.id, driverId: closestDriver.id, route: data, status: 'active' };
      activeRides[socket.id] = rideDetails;
      
      const driverInfo = { driverName: closestDriver.name, vehicle: closestDriver.vehicle };
      
      console.log(`Assigning ride to REAL driver ${closestDriver.id}.`);
      
      // Notify the patient that the ride was accepted
      io.to(rideDetails.patientId).emit('booking-accepted', driverInfo);
      // Send the start command to the chosen driver
      io.to(closestDriver.id).emit('start-ride', rideDetails);
      
    } else {
      console.log('No drivers available for patient:', socket.id);
      io.to(socket.id).emit('no-drivers-available');
    }
  });

  socket.on('driver-location-update', (data) => {
      const patientId = Object.keys(activeRides).find(pId => activeRides[pId].driverId === socket.id);
      if (patientId) {
          io.to(patientId).emit('ambulance-location-update', { lat: data.lat, lng: data.lng });
      }
  });

  socket.on('ride-finished', (data) => {
      const patientId = Object.keys(activeRides).find(pId => activeRides[pId].driverId === socket.id);
      if (patientId) {
          console.log(`Ride finished for patient ${patientId}`);
          io.to(patientId).emit('ride-finished');
          delete activeRides[patientId];
          // Add the driver back to the available pool with their new location
          availableDrivers.push({ id: socket.id, name: 'Real Driver', location: data.location }); 
      }
  });

  socket.on('disconnect', () => {
    console.log('User disconnected:', socket.id);
    // If a driver disconnects, remove them from the pool
    availableDrivers = availableDrivers.filter(driver => driver.id !== socket.id);
  });
});


const PORT = 3000;
server.listen(PORT, () => {
  console.log(`Server is running on port ${PORT}`);
  console.log('Waiting for real drivers to connect...');
});

