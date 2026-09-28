import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';

class ProductionOutputService {
  // Routes through AppConfig so every request carries x-client-id — the
  // backend (functions/api/productionOutputLogFunctions.js) is per-client
  // MySQL, keyed off that header, not a single shared Firestore collection.
  static String get _base => 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/productionOutputLog';

  // Returns empty list on 404 or any network failure so the table stays blank
  static Future<List<Map<String, dynamic>>> getAll() async {
    try {
      final res = await http.get(Uri.parse(_base), headers: AppConfig.headers).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final List<dynamic> data = jsonDecode(res.body);
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, dynamic>> create(Map<String, dynamic> body) async {
    final res = await http
        .post(
          Uri.parse(_base),
          headers: AppConfig.headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200 || res.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(res.body));
    }
    throw Exception('Failed to create entry (${res.statusCode}): ${_errorBody(res.body)}');
  }

  static Future<void> update(String id, Map<String, dynamic> body) async {
    final res = await http
        .put(
          Uri.parse('$_base/$id'),
          headers: AppConfig.headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw Exception('Failed to update entry (${res.statusCode}): ${_errorBody(res.body)}');
    }
  }

  static Future<void> delete(String id) async {
    final res = await http.delete(Uri.parse('$_base/$id'), headers: AppConfig.headers).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw Exception('Failed to delete entry (${res.statusCode}): ${_errorBody(res.body)}');
    }
  }

  // Pulls the backend's { "error": "..." } message out of the response body
  // so callers (e.g. kwh_add_data_tab.dart's catch block) can surface the
  // real reason ("Unknown column 'time' in 'field list'") instead of just a
  // bare status code. Falls back to the raw body if it isn't JSON.
  static String _errorBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] != null) return decoded['error'].toString();
    } catch (_) {}
    return body;
  }

  // Fetch machine names from equipment API with static fallback
  static Future<List<String>> getMachineNames() async {
    try {
      final res = await http.get(Uri.parse('${AppConfig.apiBase}/equipment'), headers: AppConfig.headers).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final List<dynamic> data = jsonDecode(res.body);
        final names = data.map((e) => e['name']?.toString() ?? '').where((n) => n.isNotEmpty).toSet().toList()..sort();
        if (names.isNotEmpty) return names;
      }
    } catch (_) {}
    return ['CNC-01', 'CNC-02', 'Mixer-1', 'Press-A', 'Press-B'];
  }
}
