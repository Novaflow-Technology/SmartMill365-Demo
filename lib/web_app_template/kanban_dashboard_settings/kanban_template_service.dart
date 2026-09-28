import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';

const String _baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings';

class KanbanTemplateService {
  // Save/Create a new template
  static Future<Map<String, dynamic>> saveTemplate({
    required String userId,
    required Map<String, dynamic> templateData,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/$userId'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(templateData),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Failed to save template: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error saving template: $e');
      rethrow;
    }
  }

  // Get all templates from all users
  static Future<List<Map<String, dynamic>>> getTemplateList() async {
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/list'),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonData = jsonDecode(response.body);
        final List<dynamic> templates = jsonData['data'] ?? [];

        return templates.map((t) => Map<String, dynamic>.from(t as Map)).toList();
      } else {
        throw Exception('Failed to fetch templates: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error fetching templates: $e');
      rethrow;
    }
  }

  // âœ… NEW: Apply a template
  static Future<Map<String, dynamic>> applyTemplate({
    required String userId,
    required String templateId,
    String? dashboardId,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/$userId/apply/$templateId'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'dashboardId': dashboardId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Failed to apply template: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error applying template: $e');
      rethrow;
    }
  }

  // âœ… NEW: Get active/applied settings for user
  static Future<Map<String, dynamic>?> getActiveSettings({
    required String userId,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/$userId/active'),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonData = jsonDecode(response.body);

        if (jsonData['success'] == true) {
          return jsonData;
        } else {
          return null;
        }
      } else if (response.statusCode == 404) {
        return null;
      } else {
        throw Exception('Failed to fetch active settings: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error fetching active settings: $e');
      return null;
    }
  }

  // Get templates for a specific user
  static Future<Map<String, dynamic>> getUserTemplates({
    required String userId,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/$userId'),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Failed to fetch user templates: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error fetching user templates: $e');
      rethrow;
    }
  }
}
