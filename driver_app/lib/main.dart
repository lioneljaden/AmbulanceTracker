import 'package:flutter/material.dart';
import 'driver_app_screen.dart'; // We will create this next

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ambulance Driver App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData( // A simple, functional theme for the driver
        primaryColor: Colors.deepOrange,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepOrange,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      home: const DriverAppScreen(),
    );
  }
}
