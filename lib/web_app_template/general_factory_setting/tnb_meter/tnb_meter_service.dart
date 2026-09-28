import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';
import 'tnb_meter_models.dart';
import 'tnb_meter_dashboard_config.dart';

class TnbMeterService {
  static String get _base => AppConfig.dataApiBaseSafe;
  static Map<String, String> get _headers => AppConfig.headers;

  // Same host the Max Demand Monitoring dashboard itself queries — reused
  // here so the "Live Preview" column in the TNB meter's widget-channel-
  // mapping section reflects exactly what the dashboard will show.
  static const String _energyDetailsBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails';

  /// Live preview for the 24-Hour Power Load Trend widget: point count over
  /// the last 24h for [deviceId]. Returns null on any failure (device not
  /// configured / no data / request error) so the caller can show "—".
  static Future<int?> previewPowerLoadTrendPointCount(String deviceId) async {
    if (deviceId.trim().isEmpty) return null;
    try {
      final res = await http.get(Uri.parse('$_energyDetailsBase/power-load-24h/$deviceId'), headers: _headers);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final list = data['data'] as List<dynamic>?;
        return list?.length;
      }
    } catch (e) {
      debugPrint('Error fetching power load trend preview: $e');
    }
    return null;
  }

  /// Live preview for the Daily Maximum Demand This Month widget: bar count
  /// (days logged so far this month) for [deviceId].
  static Future<int?> previewDailyMaxDemandBarCount(String deviceId) async {
    if (deviceId.trim().isEmpty) return null;
    try {
      final uri = Uri.parse('$_energyDetailsBase/max-demand-chart').replace(queryParameters: {'device_id': deviceId});
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode == 200) {
        final list = json.decode(res.body) as List<dynamic>;
        return list.length;
      }
    } catch (e) {
      debugPrint('Error fetching daily max demand preview: $e');
    }
    return null;
  }

  /// Live preview for the Power Load Distribution widget: average kW per
  /// bucket for [deviceId], computed over [buckets]' custom time windows.
  /// Returns a map keyed by bucket key (e.g. "morning") to the average kW,
  /// or null on failure.
  static Future<Map<String, double>?> previewDistributionAverages(
    String deviceId,
    List<TnbDistributionBucket> buckets,
  ) async {
    if (deviceId.trim().isEmpty || buckets.isEmpty) return null;
    try {
      final uri = Uri.parse('$_energyDetailsBase/average-power-load/$deviceId').replace(
        queryParameters: {'buckets': json.encode(buckets.map((b) => b.toJson()).toList())},
      );
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final list = data['data'] as List<dynamic>? ?? [];
        final result = <String, double>{};
        for (final item in list) {
          final key = item['key']?.toString() ?? item['time_period']?.toString() ?? '';
          if (key.isEmpty) continue;
          result[key] = (item['average_power_load_kW'] as num?)?.toDouble() ?? 0.0;
        }
        return result;
      }
    } catch (e) {
      debugPrint('Error fetching distribution preview: $e');
    }
    return null;
  }

  static Future<List<TnbMeter>> fetchMeters() async {
    try {
      // TNB meters are shared across every user of this client, not
      // per-login — no userId filter.
      final uri = Uri.parse('$_base/tnbMeters');
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode == 200) {
        final List<dynamic> data = json.decode(res.body);
        return data.map((e) => TnbMeter.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('Error fetching TNB meters: $e');
    }
    return [];
  }

  static Future<bool> createMeter(TnbMeter meter) async {
    try {
      final body = meter.toJson();
      final res = await http.post(
        Uri.parse('$_base/tnbMeters'),
        headers: _headers,
        body: json.encode(body),
      );
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (e) {
      debugPrint('Error creating TNB meter: $e');
      return false;
    }
  }

  static Future<bool> updateMeter(String id, TnbMeter meter) async {
    try {
      final body = meter.toJson();
      final res = await http.put(
        Uri.parse('$_base/tnbMeters/$id'),
        headers: _headers,
        body: json.encode(body),
      );
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (e) {
      debugPrint('Error updating TNB meter: $e');
      return false;
    }
  }

  static Future<bool> deleteMeter(String id) async {
    try {
      final res = await http.delete(
        Uri.parse('$_base/tnbMeters/$id'),
        headers: _headers,
      );
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (e) {
      debugPrint('Error deleting TNB meter: $e');
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> fetchPlants() async {
    try {
      final res = await http.get(
        Uri.parse('$_base/factory'),
        headers: _headers,
      );
      if (res.statusCode == 200) {
        return (json.decode(res.body) as List<dynamic>)
            .cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('Error fetching plants: $e');
    }
    return [];
  }

  static Future<List<Map<String, dynamic>>> fetchProductionAreas() async {
    try {
      final res = await http.get(
        Uri.parse('$_base/productionAreas'),
        headers: _headers,
      );
      if (res.statusCode == 200) {
        return (json.decode(res.body) as List<dynamic>)
            .cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('Error fetching production areas: $e');
    }
    return [];
  }

  static Future<List<Map<String, dynamic>>> fetchTariffCategories() async {
    try {
      // Tariff categories are shared across every user of this client, not
      // per-login — see AppConfig.sharedConfigOwnerId.
      final uri = Uri.parse('$_base/tariff-categories/list').replace(
        queryParameters: {'userId': AppConfig.sharedConfigOwnerId},
      );
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        final data = body is Map ? (body['data'] as List<dynamic>? ?? []) : [];
        final all = data.cast<Map<String, dynamic>>();
        return all.where((t) => t['status']?.toString() == 'Active').toList();
      }
    } catch (e) {
      debugPrint('Error fetching tariff categories: $e');
    }
    return [];
  }
}
