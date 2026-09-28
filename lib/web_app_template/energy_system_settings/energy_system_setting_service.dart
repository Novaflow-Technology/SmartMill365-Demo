import 'dart:convert';
import 'package:http/http.dart' as http;

class EnergySystemSettingsService {
  // Replace with your Firebase Functions URL
  static const String baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energy-settings';

  // Get settings for a user
  static Future<Map<String, dynamic>> getSettings(String uid) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/$uid'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to load settings: ${response.body}');
      }
    } catch (e) {
      throw Exception('Error fetching settings: $e');
    }
  }

  // Save complete settings for a user
  static Future<bool> saveSettings(String uid, Map<String, dynamic> settings) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/$uid'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(settings),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        throw Exception('Failed to save settings: ${response.body}');
      }
    } catch (e) {
      throw Exception('Error saving settings: $e');
    }
  }

  // Update specific setting type
  static Future<bool> updateSettingType(
    String uid,
    String settingType,
    Map<String, dynamic> settingData,
  ) async {
    try {
      final response = await http.patch(
        Uri.parse('$baseUrl/$uid/$settingType'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(settingData),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        throw Exception('Failed to update $settingType: ${response.body}');
      }
    } catch (e) {
      throw Exception('Error updating $settingType: $e');
    }
  }
}
