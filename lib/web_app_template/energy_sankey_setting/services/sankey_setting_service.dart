import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/flutter_flow/rbac.dart';
import 'package:smartmachine365/services/app_config.dart';
import '../models/sankey_setting_data.dart';

class SankeySettingService {
  static const String _base = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static String get _uid => AppStateNotifier.instance.uid ?? '';

  static List<String>? _deviceCache;

  static Future<Map<String, dynamic>> getSetting() async {
    try {
      final res = await http.get(Uri.parse('$_base/sanky-flow-settings/$_uid'),
          headers: {
            'Content-Type': 'application/json'
          }).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {'tiers': [], 'nodes': []};
  }

  static Future<bool> saveSetting({
    required List<SankeyTier> tiers,
    required List<SankeyNode> nodes,
  }) async {
    final flowLinks = _buildFlowLinks(nodes);
    final res = await http
        .post(Uri.parse('$_base/sanky-flow-settings/$_uid'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'tiers': tiers.map((t) => t.toMap()).toList(),
              'nodes': nodes.map((n) => n.toMap()).toList(),
              'flowLinks': flowLinks,
            }))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return true;
    throw Exception('Save failed: ${res.body}');
  }

  static List<Map<String, String>> _buildFlowLinks(List<SankeyNode> nodes) {
    final byId = {for (final node in nodes) node.id: node};
    final links = <Map<String, String>>[];
    for (final source in nodes) {
      final sourceId = source.id.trim();
      // Save must follow latest UI assignment first (fields), then legacy tag.
      final flowTag = source.fields.firstWhere(
        (field) => field.trim().isNotEmpty,
        orElse: () => source.flowValueTag.trim(),
      );
      if (sourceId.isEmpty || flowTag.isEmpty) continue;
      for (final destinationId in source.targetIds) {
        final destinationNode = byId[destinationId];
        if (destinationNode == null) continue;
        final masterFacilityId = source.masterFacilityId.trim().isNotEmpty
            ? source.masterFacilityId.trim()
            : destinationNode.masterFacilityId.trim();
        if (masterFacilityId.isEmpty) continue;
        links.add({
          'master_facility_id': masterFacilityId,
          'source_node_id': sourceId,
          'destination_node_id': destinationNode.id,
          'flow_value_tag': flowTag,
        });
      }
    }
    return links;
  }

  // Uses the energy-data server (same host as influxdb_service) for device list
  static const String _devicesUrl =
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/devices';
  static const String _facilitiesUrl =
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/facilities';

  static Future<List<String>> getDeviceList({bool forceRefresh = false}) async {
    if (_deviceCache != null && !forceRefresh) return _deviceCache!;
    try {
      final res = await http
          .get(Uri.parse(_devicesUrl), headers: AppConfig.headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        // API returns {"value": [...], "Count": N}  OR  plain [...].
        final List<dynamic> list = body is Map
            ? ((body['value'] ?? body['data'] ?? []) as List<dynamic>)
            : (body as List<dynamic>);
        _deviceCache = list
            .map((e) =>
                (e as Map<String, dynamic>)['device_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList()
          ..sort();
        return _deviceCache!;
      }
    } catch (_) {}
    return [];
  }

  static Future<List<Map<String, String>>> getEquipmentList() async {
    try {
      final res = await http
          .get(Uri.parse('$_base/equipment'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final List<dynamic> list = json.decode(res.body);
        return list.map((e) {
          final map = e as Map<String, dynamic>;
          return {
            'id': map['equipment_id']?.toString() ?? '',
            'name': map['name']?.toString() ?? '',
          };
        }).where((m) => m['id']!.isNotEmpty).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<List<MasterFacilityTemplate>> getMasterFacilities() async {
    try {
      final res = await http
          .get(
            Uri.parse('$_facilitiesUrl/$_uid'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final body = json.decode(res.body);
      if (body is! List) return [];
      return body
          .whereType<Map>()
          .map((raw) => MasterFacilityTemplate.fromMap(
              raw.cast<String, dynamic>()))
          .where((item) => item.id.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }
}

class MasterFacilityTemplate {
  final String id;
  final String factory;
  final String equipmentNameId;
  final String meterId;
  final String meterName;

  const MasterFacilityTemplate({
    required this.id,
    required this.factory,
    required this.equipmentNameId,
    required this.meterId,
    required this.meterName,
  });

  factory MasterFacilityTemplate.fromMap(Map<String, dynamic> map) {
    return MasterFacilityTemplate(
      id: map['id']?.toString() ?? '',
      factory: map['factory']?.toString() ?? '',
      equipmentNameId: map['equipmentNameId']?.toString() ?? '',
      meterId: map['meterId']?.toString() ?? '',
      meterName: map['meterName']?.toString() ?? '',
    );
  }

  String get nodeLabel {
    final candidates = [equipmentNameId, meterName, meterId, id];
    for (final value in candidates) {
      final text = value.trim();
      if (text.isNotEmpty) return text;
    }
    return id;
  }

  String get nodeDeviceId {
    final candidates = [meterId, equipmentNameId, meterName];
    for (final value in candidates) {
      final text = value.trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}
