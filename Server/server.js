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

let availableDrivers = [];
let activeRides = {};

function getDistanceFromLatLonInKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = deg2rad(lat2 - lat1);
  const dLon = deg2rad(lon2 - lon1);
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(deg2rad(lat1)) * Math.cos(deg2rad(lat2)) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}
function deg2rad(deg) { return deg * (Math.PI / 180); }

io.on('connection', (socket) => {
  console.log('A user connected:', socket.id);

  socket.on('driver-online', (driverData) => {
    console.log('A real driver has come online:', socket.id);
    const existingDriverIndex = availableDrivers.findIndex(d => d.id === socket.id);
    if (existingDriverIndex > -1) {
      availableDrivers[existingDriverIndex].location = driverData.location;
    } else {
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
      return console.error("Invalid pickup location data received.");
    }

    const driversWithLocation = availableDrivers.filter(d => d.location);
    if (driversWithLocation.length > 0) {
      let closestDriver = driversWithLocation.reduce((prev, curr) => {
        const prevDistance = getDistanceFromLatLonInKm(pickupLocation.lat, pickupLocation.lng, prev.location.lat, prev.location.lng);
        const currDistance = getDistanceFromLatLonInKm(pickupLocation.lat, pickupLocation.lng, curr.location.lat, curr.location.lng);
        return (prevDistance < currDistance) ? prev : curr;
      });
      
      availableDrivers = availableDrivers.filter(driver => driver.id !== closestDriver.id);
      
      const rideDetails = { patientId: socket.id, driverId: closestDriver.id, route: data, status: 'en_route_to_pickup' };
      activeRides[socket.id] = rideDetails;
      
      const driverInfo = { driverName: closestDriver.name, vehicle: closestDriver.vehicle, driverLocation: closestDriver.location };
      
      console.log(`Assigning ride to REAL driver ${closestDriver.id}.`);
      
      io.to(rideDetails.patientId).emit('booking-accepted', driverInfo);
      io.to(closestDriver.id).emit('start-ride', rideDetails);
      
    } else {
      console.log('No drivers available for patient:', socket.id);
      io.to(socket.id).emit('no-drivers-available');
    }
  });

  // NEW: Event for when the driver picks up the patient
  socket.on('driver-picked-up-patient', (data) => {
      const patientId = data.patientId;
      if (patientId && activeRides[patientId]) {
          console.log(`Driver picked up patient ${patientId}. Journey to hospital begins.`);
          activeRides[patientId].status = 'en_route_to_hospital';
          // Notify the patient that the next leg of the journey has started
          io.to(patientId).emit('en-route-to-hospital');
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
          availableDrivers.push({ id: socket.id, name: 'Real Driver', location: data.location }); 
      }
  });

  socket.on('disconnect', () => {
    console.log('User disconnected:', socket.id);
    availableDrivers = availableDrivers.filter(driver => driver.id !== socket.id);
  });
});

const PORT = 3000;
server.listen(PORT, () => {
  console.log(`Server is running on port ${PORT}`);
  console.log('Waiting for real drivers to connect...');
});

