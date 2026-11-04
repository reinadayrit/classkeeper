import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class LocationService {
  /// Checks location permissions and fetches current GPS coordinates.
  /// Throws an [Exception] if location services are disabled or permissions are denied.
  static Future<Position> getCurrentPosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    // 1. Check if location services (GPS) are enabled on the device
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception(
        'Location services are disabled. Please enable GPS on your device.',
      );
    }

    // 2. Check current location permission status
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // Request permission if not yet granted
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission was denied.');
      }
    }

    // 3. Handle permanently denied permissions
    if (permission == LocationPermission.deniedForever) {
      throw Exception(
        'Location permissions are permanently denied. Please enable location permissions in your device settings.',
      );
    }

    // 4. Fetch position with balanced accuracy
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (e) {
      debugPrint('Error getting location: $e');
      throw Exception('Failed to get current location coordinates: $e');
    }
  }

  /// Calculates distance in meters between two GPS coordinate sets.
  static double calculateDistanceMeters({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) {
    return Geolocator.distanceBetween(
      startLatitude,
      startLongitude,
      endLatitude,
      endLongitude,
    );
  }

  /// Helper method to verify if a student's current location is within
  /// the allowed classroom radius (default 30 meters).
  static bool isWithinClassroomRadius({
    required double studentLat,
    required double studentLng,
    required double classLat,
    required double classLng,
    double allowedRadiusMeters = 30.0,
  }) {
    final distance = calculateDistanceMeters(
      startLatitude: studentLat,
      startLongitude: studentLng,
      endLatitude: classLat,
      endLongitude: classLng,
    );

    return distance <= allowedRadiusMeters;
  }
}
