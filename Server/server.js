const express = require('express');
const http = require('http');
const { Server } = require("socket.io");

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*", // Allow all origins for development
  },
});

const PORT = 3000;

// In-memory storage for active bookings
const activeBookings = new Map();

io.on('connection', (socket) => {
  console.log('A client connected:', socket.id);

  // Listen for a new booking request from a patient
  socket.on('request-booking', (bookingData) => {
    console.log(`Booking request received from ${socket.id}`);

    // Store the booking details
    activeBookings.set(socket.id, {
      patientId: socket.id,
      route: bookingData.route,
      simulationInterval: null,
      currentStep: 0,
    });
    
    // --- SIMULATION: A driver accepts the request after a few seconds ---
    setTimeout(() => {
      const booking = activeBookings.get(socket.id);
      if (!booking) return; // Patient might have disconnected

      console.log(`Booking for ${socket.id} accepted. Starting simulation.`);
      // Notify the patient that the booking is confirmed
      socket.emit('booking-accepted', { driverName: 'John Doe', vehicle: 'Ambulance-108' });

      // Start the ambulance movement simulation
      booking.simulationInterval = setInterval(() => {
        const currentBooking = activeBookings.get(socket.id);
        if (!currentBooking) {
            // Clean up if booking is gone
            clearInterval(booking.simulationInterval);
            return;
        }

        // Move to the next point on the route
        currentBooking.currentStep++;
        
        // Check if the ride is finished
        if (currentBooking.currentStep >= currentBooking.route.coordinates.length) {
          console.log(`Ride for ${socket.id} finished.`);
          socket.emit('ride-finished');
          clearInterval(currentBooking.simulationInterval);
          activeBookings.delete(socket.id);
          return;
        }
        
        const newLocation = currentBooking.route.coordinates[currentBooking.currentStep];
        
        // Send the updated ambulance location to the patient
        socket.emit('ambulance-location-update', {
          lat: newLocation.lat,
          lng: newLocation.lng,
        });

      }, 2000); // Update location every 2 seconds

    }, 5000); // Driver accepts after 5 seconds
  });

  socket.on('cancel-booking', () => {
      console.log(`Booking cancelled by ${socket.id}`);
      const booking = activeBookings.get(socket.id);
      if (booking && booking.simulationInterval) {
          clearInterval(booking.simulationInterval);
      }
      activeBookings.delete(socket.id);
  });

  socket.on('disconnect', () => {
    console.log('Client disconnected:', socket.id);
    // Clean up any active booking simulations for the disconnected client
    const booking = activeBookings.get(socket.id);
    if (booking && booking.simulationInterval) {
      clearInterval(booking.simulationInterval);
    }
    activeBookings.delete(socket.id);
  });
});

server.listen(PORT, () => {
  console.log(`Server is running on port ${PORT}`);
});

