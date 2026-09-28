import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/energy_sankey_setting/models/sankey_setting_data.dart';
import 'widgets/sankey_chart_widget.dart' as chart;

const _kTierColors = [
  0xFFB85C38, 0xFF5A9F6A, 0xFF4A90D9, 0xFF9B59B6, 0xFF6EC6B0, 0xFFE74C3C,
];
int _colorFor(int col) => _kTierColors[col.clamp(0, _kTierColors.length - 1)];

class SankeyFlowData {
  final List<chart.SankeyNode> nodes;
  final List<chart.SankeyLink> links;
  final DateTime fetchedAt;
  const SankeyFlowData({required this.nodes, required this.links, required this.fetchedAt});
}

class SankeyFlowService {
  static const String _settingsBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/sanky-flow-settings';
  static const String _facilityBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/facilities';
  // NOTE: Energy Details / PECC use this endpoint for "Current Load (kW)".
  static const String _influxCurrentLoadBase =
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/power-load/current';

  // Legacy realtime endpoint used for non-kW fields (voltage/current/etc).
  static const String _influxRealtimeBase =
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/realtime';

  // Fallback (MySQL aggregated) used across the app when Influx current returns 0.
  static const String _powerLoad24hBase =
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/power-load-24h';
  static const String _energyBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/total';

  static String get _uid => AppStateNotifier.instance.uid ?? '';

  static Future<bool> regenerateTemplate() async {
    final uid = _uid;
    if (uid.isEmpty) throw Exception('User not authenticated');
    final rebuilt = await _buildTemplateFromMasterFacility(uid);
    return rebuilt != null;
  }

  static Future<SankeyFlowData> load({bool forceRebuildTemplate = false}) async {
    final uid = _uid;
    if (uid.isEmpty) return SankeyFlowData(nodes: [], links: [], fetchedAt: DateTime.now());

    Map<String, dynamic> raw;
    try {
      raw = await _fetchSettingRaw(uid);
      if (forceRebuildTemplate || _isSettingEmpty(raw)) {
        raw = await _buildTemplateFromMasterFacility(uid) ?? raw;
      }
      if (_isSettingEmpty(raw)) return SankeyFlowData(nodes: [], links: [], fetchedAt: DateTime.now());
    } catch (_) {
      return SankeyFlowData(nodes: [], links: [], fetchedAt: DateTime.now());
    }

    final tiers = (raw['tiers'] as List<dynamic>? ?? [])
        .map((e) => SankeyTier.fromMap(e as Map<String, dynamic>))
        .toList()..sort((a, b) => a.order.compareTo(b.order));

    final tierColIdx = {for (int i = 0; i < tiers.length; i++) tiers[i].id: i};
    var settingNodes = (raw['nodes'] as List<dynamic>? ?? [])
        .map((e) => SankeyNode.fromMap(e as Map<String, dynamic>))
        .toList();

    if (tiers.isEmpty || settingNodes.isEmpty) return SankeyFlowData(nodes: [], links: [], fetchedAt: DateTime.now());

    // Auto-upgrade legacy flat templates (single source -> all devices) so
    // the chart can resemble the reference multi-stage Sankey layout.
    //
    // IMPORTANT: Do NOT auto-upgrade if the user intentionally saved a simple
    // 2-tier template (Source -> Devices). That layout should be preserved.
    final firstTierId = tiers.first.id;
    final hasAnyBranch = settingNodes.any((n) => n.targetIds.isNotEmpty);
    final flatTopology = hasAnyBranch &&
        settingNodes.where((n) => n.targetIds.isNotEmpty).every((n) => n.tierId == firstTierId);
    if (flatTopology && tiers.length > 2) {
      final rebuilt = await _buildTemplateFromMasterFacility(uid);
      if (rebuilt != null) {
        raw = rebuilt;
        final rebuiltTiers = (raw['tiers'] as List<dynamic>? ?? [])
            .map((e) => SankeyTier.fromMap(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
        final rebuiltTierIdx = {for (int i = 0; i < rebuiltTiers.length; i++) rebuiltTiers[i].id: i};
        final rebuiltNodes = (raw['nodes'] as List<dynamic>? ?? [])
            .map((e) => SankeyNode.fromMap(e as Map<String, dynamic>))
            .toList();
        if (rebuiltTiers.isNotEmpty && rebuiltNodes.isNotEmpty) {
          // Replace local working copies.
          tiers
            ..clear()
            ..addAll(rebuiltTiers);
          tierColIdx
            ..clear()
            ..addAll(rebuiltTierIdx);
          settingNodes = rebuiltNodes;
        }
      }
    }

    final facilityLabelById = await _fetchFacilityLabelById(uid);
    settingNodes = settingNodes.where((n) => !n.removed).toList();

    final allTargetIds = settingNodes.expand((n) => n.targetIds).toSet();
    settingNodes = settingNodes.where((n) {
      if (n.deviceId.isNotEmpty) return true;
      if (allTargetIds.contains(n.id)) return true;
      if (n.targetIds.isNotEmpty) return true;
      return false;
    }).toList();

    final nodeIdSet = settingNodes.map((n) => n.id).toSet();
    final Map<String, double> directVal = {};
    final Map<String, double> directRawVal = {};
    final Map<String, String> representativeFieldByNode = {};
    for (final n in settingNodes) {
      // Thickness/flow is driven by the strongest mapped power signal
      // across this node's configured mapping fields.
      final flowFields = _selectedFieldsForNode(n);
      if (n.deviceId.isNotEmpty) {
        final rep = await _fetchRepresentativeFlow(n.deviceId, flowFields);
        directRawVal[n.id] = rep.value;
        directVal[n.id] = rep.value;
        representativeFieldByNode[n.id] = rep.field;
      } else {
        directRawVal[n.id] = 0.0;
        directVal[n.id] = 0.0;
      }
    }

    final sortedDesc = List<SankeyNode>.from(settingNodes)
      ..sort((a, b) => (tierColIdx[b.tierId] ?? 0).compareTo(tierColIdx[a.tierId] ?? 0));

    final effVal = <String, double>{};
    final hasMeasuredData = <String, bool>{};
    for (final n in sortedDesc) {
      final children = n.targetIds.where(nodeIdSet.contains).toList();
      final direct = directVal[n.id] ?? 0.0;
      double v;
      final childMeasured = children.any((cid) => hasMeasuredData[cid] == true);
      hasMeasuredData[n.id] = (direct > 0) || childMeasured;
      // IMPORTANT: keep missing data as 0.0 (do not fake 1 kW).
      // Visual thickness is handled by the renderer, not by inflating values.
      if (children.isEmpty) { v = direct; }
      else if (direct > 0) { v = direct; }
      else {
        final sum = children.fold(0.0, (s, cid) => s + (effVal[cid] ?? 0.0));
        v = sum;
      }
      effVal[n.id] = v < 0 ? 0.0 : v;
    }

    final virtualOthersNodes = <chart.SankeyNode>[];
    final virtualOthersLinks = <chart.SankeyLink>[];
    final int lastCol = tiers.isNotEmpty ? tiers.length - 1 : 1;

    for (final n in settingNodes) {
      final childrenIds = n.targetIds.where(nodeIdSet.contains).toList();
      if (childrenIds.isEmpty) continue;
      // Legacy Others formula applies at source level only:
      // Others = Main Source - measured downstream devices.
      final col = tierColIdx[n.tierId] ?? 0;
      if (col != 0) continue;
      final double parentMeasured = directRawVal[n.id] ?? 0.0;
      // Legacy rule requested:
      // Others = Parent measured power - sum(children with measured data).
      if (parentMeasured > 0) {
        final double measuredChildrenSum = childrenIds.fold(0.0, (s, id) {
          if (hasMeasuredData[id] == true) return s + (effVal[id] ?? 0.0);
          return s;
        });
        final double remainder = parentMeasured - measuredChildrenSum;
        if (remainder <= 0.5) continue;
        final String othersId = 'others_${n.id}';
        virtualOthersNodes.add(chart.SankeyNode(
          id: othersId, label: 'Others / Unaccounted', value: remainder,
          color: const Color(0xFF607D8B), column: (tierColIdx[n.tierId] ?? 0) + 1, unit: 'kW',
          tierLabel: 'Others', mappingLabel: 'Active Power', extraPills: ['Formula: Parent - measured devices'],
        ));
        virtualOthersLinks.add(chart.SankeyLink(sourceId: n.id, targetId: othersId, value: remainder));
      }
    }

    final tierLabelById = {for (final t in tiers) t.id: t.label};
    final tierColorById = {for (final t in tiers) t.id: t.colorHex};
    final sourceNodes = settingNodes.where((n) => (tierColIdx[n.tierId] ?? 0) == 0).toList();
    final double totalFlow = sourceNodes.fold(0.0, (s, n) => s + (effVal[n.id] ?? 0.0));
    final List<chart.SankeyNode> chartNodes = settingNodes.map((n) {
      final selectedField =
          representativeFieldByNode[n.id] ?? _selectedFieldForNode(n);
      final flowField = selectedField;
      final nodeVal = effVal[n.id] ?? 1.0;
      final pct = totalFlow > 0 ? (nodeVal / totalFlow) * 100.0 : 0.0;
      final extra = <String>[];
      if ((tierColIdx[n.tierId] ?? 0) > 0) {
        extra.add('Share: ${pct.toStringAsFixed(1)}%');
      }
      final nodeUnit = _unitFor(flowField);
      final nodeValueLabel = nodeUnit == 'kW' ? 'Power' : 'Energy';
      extra.add('$nodeValueLabel: ${nodeVal.toStringAsFixed(1)} $nodeUnit');
      Color? parseHexColor(String hex) {
        final raw = hex.trim();
        if (raw.isEmpty) return null;
        final cleaned = raw.startsWith('#') ? raw.substring(1) : raw;
        if (cleaned.length == 6) {
          final parsed = int.tryParse('FF$cleaned', radix: 16);
          return parsed == null ? null : Color(parsed);
        }
        if (cleaned.length == 8) {
          final parsed = int.tryParse(cleaned, radix: 16);
          return parsed == null ? null : Color(parsed);
        }
        return null;
      }
      final defaultColor = Color(_colorFor(tierColIdx[n.tierId] ?? 0));
      final nodeCustom = parseHexColor(n.colorHex);
      final tierDefault = parseHexColor(tierColorById[n.tierId] ?? '');
      final resolvedColor = nodeCustom ?? tierDefault ?? defaultColor;
      return chart.SankeyNode(
        id: n.id, label: _resolveNodeLabel(n, facilityLabelById, tierLabelById[n.tierId] ?? ''),
        value: nodeVal, color: resolvedColor,
        column: tierColIdx[n.tierId] ?? 0, unit: _unitFor(flowField),
        tierLabel: tierLabelById[n.tierId] ?? '',
        mappingLabel: _mappingLabelForField(selectedField),
        extraPills: extra,
      );
    }).toList();
    chartNodes.addAll(virtualOthersNodes);

    final chartLinks = <chart.SankeyLink>[];
    for (final src in settingNodes) {
      for (final tid in src.targetIds) {
        if (!nodeIdSet.contains(tid)) continue;
        chartLinks.add(chart.SankeyLink(sourceId: src.id, targetId: tid, value: effVal[tid] ?? 1.0));
      }
    }
    chartLinks.addAll(virtualOthersLinks);

    // ── Flatten transparent intermediate nodes ──────────────────────────────
    // When every intermediate node (column > 0 AND column < maxCol) has no
    // device and zero measured value, it is a pure aggregation placeholder.
    // Flatten those away so the chart renders as a clean 2-column fan-out
    // (each source directly to its leaf equipment) instead of showing
    // invisible pinch-point bars in the middle.
    final nodeByIdSetting = {for (final n in settingNodes) n.id: n};
    bool isTransparent(String id) {
      final n = nodeByIdSetting[id];
      return n != null && n.deviceId.isEmpty && (effVal[id] ?? 0.0) <= 0.0;
    }

    final allChartCols = chartNodes.map((n) => n.column);
    final maxChartCol = allChartCols.isEmpty ? 0 : allChartCols.reduce((a, b) => a > b ? a : b);

    final intermediateTransparentIds = chartNodes
        .where((n) => n.column > 0 && n.column < maxChartCol && isTransparent(n.id))
        .map((n) => n.id)
        .toSet();

    // Only check real setting nodes (not virtual ones like Others/Unaccounted).
    final allIntermediatesTransparent = maxChartCol > 1 &&
        chartNodes
            .where((n) => n.column > 0 && n.column < maxChartCol && nodeByIdSetting.containsKey(n.id))
            .every((n) => intermediateTransparentIds.contains(n.id));

    if (allIntermediatesTransparent) {
      // Resolve leaf nodes reachable from a node, skipping transparent intermediates.
      Set<String> resolveLeaves(String id, {int depth = 0}) {
        if (depth > 20) return {id};
        if (!isTransparent(id)) return {id};
        final sn = nodeByIdSetting[id];
        if (sn == null) return {id};
        final result = <String>{};
        for (final tid in sn.targetIds) {
          if (!nodeIdSet.contains(tid)) continue;
          result.addAll(resolveLeaves(tid, depth: depth + 1));
        }
        return result.isEmpty ? {id} : result;
      }

      // New nodes: keep only col-0 sources and col-maxChartCol leaves;
      // promote leaves to column 1 for a clean 2-column layout.
      final flatNodes = chartNodes
          .where((n) => !intermediateTransparentIds.contains(n.id))
          .map((n) {
            if (n.column == maxChartCol) {
              return chart.SankeyNode(
                id: n.id, label: n.label, value: n.value, color: n.color,
                column: 1, unit: n.unit, tierLabel: n.tierLabel,
                mappingLabel: n.mappingLabel, extraPills: n.extraPills,
              );
            }
            return n;
          })
          .toList();

      // New links: col-0 sources → resolved leaves (direct).
      final flatLinks = <chart.SankeyLink>[];
      final flatNodeIds = flatNodes.map((n) => n.id).toSet();
      for (final src in settingNodes.where((n) => (tierColIdx[n.tierId] ?? 0) == 0)) {
        for (final tid in src.targetIds) {
          if (!nodeIdSet.contains(tid)) continue;
          for (final leafId in resolveLeaves(tid)) {
            if (!flatNodeIds.contains(leafId)) continue;
            flatLinks.add(chart.SankeyLink(sourceId: src.id, targetId: leafId, value: effVal[leafId] ?? 0.0));
          }
        }
      }
      flatLinks.addAll(virtualOthersLinks);

      return SankeyFlowData(nodes: flatNodes, links: flatLinks, fetchedAt: DateTime.now());
    }

    return SankeyFlowData(nodes: chartNodes, links: chartLinks, fetchedAt: DateTime.now());
  }

  static Future<double> _fetchValue(String deviceId, String field) async {
    if (deviceId.isEmpty || field.isEmpty) return 0.0;
    if (field.contains('kWh')) return _fetchTotal(deviceId, field.replaceAll('_kWh', ''));
    return _fetchInflux(deviceId, field);
  }

  static Future<double> _fetchCombinedValue(String deviceId, List<String> fields) async {
    final cleaned = fields.map(_cleanField).where((f) => f.isNotEmpty).toList();
    if (cleaned.isEmpty) return _fetchValue(deviceId, 'P(kW)');
    double sum = 0.0;
    for (final f in cleaned) {
      sum += await _fetchValue(deviceId, f);
    }
    return sum;
  }

  static Future<double> _fetchRepresentativeFlowValue(
      String deviceId, List<String> fields) async {
    final rep = await _fetchRepresentativeFlow(deviceId, fields);
    return rep.value;
  }

  // Respects all fields the user configured in settings — no filtering by
  // unit type. Picks the field with the highest fetched value among all
  // configured fields so the most meaningful signal drives the flow width.
  static Future<({String field, double value})> _fetchRepresentativeFlow(
      String deviceId, List<String> fields) async {
    final cleaned = fields.map(_cleanField).where((f) => f.isNotEmpty).toList();
    if (cleaned.isEmpty) {
      final v = await _fetchValue(deviceId, 'P(kW)');
      return (field: 'P(kW)', value: v);
    }

    String bestField = cleaned.first;
    double bestVal = 0.0;
    for (final f in cleaned) {
      final v = await _fetchValue(deviceId, f);
      if (v > bestVal) {
        bestVal = v;
        bestField = f;
      }
    }
    return (field: bestField, value: bestVal);
  }

  static Future<double> _fetchInflux(String deviceId, String field) async {
    final cleaned = _cleanField(field).toLowerCase();

    // Align Sankey flow (kW) with Energy Details / PECC current load.
    final isKw = cleaned.contains('kw') || cleaned == 'p' || cleaned.contains('p(') || cleaned.contains('active');
    if (isKw) {
      final kw = await _fetchCurrentLoadKw(deviceId);
      if (kw > 0) return kw;
      return _fetchPowerLoad24hFallbackKw(deviceId);
    }

    // Non-kW fields keep using the realtime endpoint (per-field fetch).
    try {
      final res = await http
          .get(
            Uri.parse('$_influxRealtimeBase/$deviceId?fields=$field'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return 0.0;
      final body = json.decode(res.body);
      final list = body is Map ? (body['value'] ?? []) : (body is List ? body : []);
      for (final item in list) {
        if (item is Map && item['field'] == field) {
          final v = item['value'];
          if (v is num) return v.toDouble();
          return double.tryParse(v?.toString() ?? '') ?? 0.0;
        }
      }
    } catch (_) {}
    return 0.0;
  }

  static Future<double> _fetchCurrentLoadKw(String deviceId) async {
    if (deviceId.isEmpty) return 0.0;
    try {
      final res = await http
          .get(
            Uri.parse('$_influxCurrentLoadBase?deviceId=${Uri.encodeComponent(deviceId)}'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return 0.0;
      final body = json.decode(res.body);
      if (body is! Map) return 0.0;
      final v = body['power_kw'];
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  static Future<double> _fetchPowerLoad24hFallbackKw(String deviceId) async {
    if (deviceId.isEmpty) return 0.0;
    try {
      final res = await http
          .get(
            Uri.parse('$_powerLoad24hBase/${Uri.encodeComponent(deviceId)}'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 0.0;
      final body = json.decode(res.body);
      if (body is! Map) return 0.0;

      // Prefer the latest 30-min bucket when available.
      final data = body['data'];
      if (data is List && data.isNotEmpty) {
        final last = data.last;
        if (last is Map) {
          final v = last['max_demand_kW'];
          final parsed = (v is num) ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;
          if (parsed > 0) return parsed;
        }
      }

      // Otherwise fall back to statistics.current_max_demand_kW.
      final stats = body['statistics'];
      if (stats is Map) {
        final v = stats['current_max_demand_kW'] ?? stats['max_demand_kW'];
        if (v is num) return v.toDouble();
        return double.tryParse(v?.toString() ?? '') ?? 0.0;
      }
    } catch (_) {}
    return 0.0;
  }

  static Future<double> _fetchTotal(String deviceId, String period) async {
    try {
      final res = await http.get(Uri.parse('$_energyBase/$deviceId'), headers: AppConfig.headers).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return 0.0;
      final body = json.decode(res.body);
      final list = body is List ? body : [];
      for (final item in list) { if (item['period'] == period) return (item['total_energy'] ?? 0).toDouble(); }
    } catch (_) {}
    return 0.0;
  }

  static String _cleanField(String raw) => raw.split(' - ').first.split(' — ').first.trim();
  static String _primaryField(List<String> fields) => fields.map(_cleanField).firstWhere((f) => f.isNotEmpty, orElse: () => 'P(kW)');
  static String _selectedFieldForNode(SankeyNode n) {
    final fromFields = _primaryField(n.fields);
    if (fromFields.isNotEmpty) return fromFields;
    final fromTag = _cleanField(n.flowValueTag);
    if (fromTag.isNotEmpty) return fromTag;
    return 'P(kW)';
  }
  static List<String> _selectedFieldsForNode(SankeyNode n) {
    final fromFields = n.fields.map(_cleanField).where((f) => f.isNotEmpty).toList();
    if (fromFields.isNotEmpty) {
      return fromFields.toSet().toList();
    }
    final fromTag = _cleanField(n.flowValueTag);
    if (fromTag.isNotEmpty) return [fromTag];
    return ['P(kW)'];
  }
  static String _flowFieldForNode(SankeyNode n) {
    final cleaned = n.fields.map(_cleanField).where((f) => f.isNotEmpty).toList();
    for (final f in cleaned) {
      final lower = f.toLowerCase();
      if (lower.contains('kw') || lower == 'p' || lower.contains('p(') || lower.contains('active')) {
        return f;
      }
    }
    final selected = _selectedFieldForNode(n);
    final lower = selected.toLowerCase();
    if (lower.contains('kw') || lower == 'p' || lower.contains('p(') || lower.contains('active')) {
      return selected;
    }
    return 'P(kW)';
  }
  static String _unitFor(String field) {
    final f = _cleanField(field).toLowerCase();
    // Named energy fields from settings dropdown
    if (f == 'edel' || f == 'erec') return 'kWh';
    if (f == 'eapp') return 'kVAh';
    if (f.contains('kwh')) return 'kWh';
    if (f.contains('kvah')) return 'kVAh';
    return 'kW';
  }

  static String _mappingLabelForField(String field) {
    final f = _cleanField(field).toLowerCase();
    if (f.contains('peak') || f.contains('demand')) return 'Peak Demand';
    if (f == 'edel') return 'Energy Delivered';
    if (f == 'erec') return 'Energy Received';
    if (f == 'eapp') return 'Apparent Energy';
    if (f.contains('daily')) return 'Daily Usage';
    if (f.contains('monthly')) return 'Monthly Usage';
    if (f.contains('yearly')) return 'Yearly Usage';
    if (f.contains('kwh') || f.contains('energy')) return 'Energy';
    if (f.contains('kva') || f.contains('apparent')) return 'Apparent Power';
    if (f.contains('kw') || f.contains('active') || f.contains('p(') || f == 'p') return 'Active Power';
    final cleaned = _cleanField(field);
    return cleaned.isEmpty ? 'Active Power' : cleaned;
  }

  static final Map<String, ({List<dynamic> facilities, DateTime time})> _sankeyFacilityCache = {};

  static Future<List<dynamic>> _getFacilitiesForUid(String uid, {bool forceRefresh = false}) async {
    final cached = _sankeyFacilityCache[uid];
    if (!forceRefresh && cached != null && DateTime.now().difference(cached.time) < const Duration(minutes: 2)) {
      return cached.facilities;
    }
    try {
      final res = await http.get(Uri.parse('$_facilityBase/$uid')).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final List facilities = json.decode(res.body);
        _sankeyFacilityCache[uid] = (facilities: facilities, time: DateTime.now());
        return facilities;
      }
    } catch (_) {}
    return cached?.facilities ?? [];
  }

  static Future<Map<String, String>> _fetchFacilityLabelById(String uid, {bool forceRefresh = false}) async {
    try {
      final body = await _getFacilitiesForUid(uid, forceRefresh: forceRefresh);
      return {for (var item in body) if (item['id'] != null) item['id'].toString(): _bestFacilityLabel(item)};
    } catch (_) { return {}; }
  }

  static String _bestFacilityLabel(Map f) {
    final candidates = [
      f['equipmentNameId'],
      f['meterName'],
      f['equipmentType'],
      f['plant'],
      f['id'],
    ];
    for (final c in candidates) {
      final s = _cleanLabel(c?.toString() ?? '');
      if (_isMeaningfulLabel(s)) return s;
    }
    return 'Unnamed Equipment';
  }

  static String _resolveNodeLabel(SankeyNode node, Map<String, String> labels, String tier) {
    final nodeLabel = _cleanLabel(node.label);
    if (node.deviceId.isEmpty && tier.toLowerCase() != 'equipment') {
      return _isMeaningfulLabel(nodeLabel) ? nodeLabel : 'Uncategorized';
    }
    final byFacility = _cleanLabel(labels[node.masterFacilityId] ?? '');
    if (_isMeaningfulLabel(byFacility)) return byFacility;
    final byNode = _cleanLabel(labels[node.id] ?? '');
    if (_isMeaningfulLabel(byNode)) return byNode;
    final byDevice = _cleanLabel(node.deviceId);
    if (_isMeaningfulLabel(byDevice)) return byDevice;
    if (_isMeaningfulLabel(nodeLabel)) return nodeLabel;
    return 'Unnamed Equipment';
  }

  static Future<Map<String, dynamic>> _fetchSettingRaw(String uid) async {
    final res = await http.get(Uri.parse('$_settingsBase/$uid')).timeout(const Duration(seconds: 10));
    return (res.statusCode == 200) ? json.decode(res.body) : {'tiers': [], 'nodes': []};
  }

  static bool _isSettingEmpty(Map raw) => (raw['tiers'] as List?)?.isEmpty ?? true;

  static Future<Map<String, dynamic>?> _buildTemplateFromMasterFacility(String uid, {bool forceRefresh = false}) async {
    final facilities = await _getFacilitiesForUid(uid, forceRefresh: forceRefresh);
    if (facilities.isEmpty) return null;

    final tiers = [
      {'id': 'tier_source', 'label': 'Main Source', 'order': 0},
      {'id': 'tier_hall', 'label': 'Area', 'order': 1},
      {'id': 'tier_dist_1', 'label': 'Distribution', 'order': 2},
      {'id': 'tier_equipment', 'label': 'Equipment', 'order': 3},
    ];
    final nodes = <Map<String, dynamic>>[];
    nodes.add({
      'id': 'src_main',
      'tierId': 'tier_source',
      'label': 'Main Incomer',
      'deviceId': '',
      'fields': ['P(kW)'],
      'targetIds': <String>[],
      'removed': false
    });

    final sourceTargets = (nodes[0]['targetIds'] as List<String>);
    final areaTargetsByKey = <String, List<String>>{};
    final distributionTargetsByKey = <String, List<String>>{};

    final areaCounts = <String, int>{};
    final distCountsByArea = <String, Map<String, int>>{};
    for (final f in facilities) {
      final rawArea = _pickGroupingLabel(
        f,
        const ['plant', 'lineName', 'area', 'department'],
        fallback: 'Main Area',
      );
      final rawDist = _pickGroupingLabel(
        f,
        const ['equipmentType', 'panelName', 'meterGroup', 'category'],
        fallback: 'Distribution',
      );
      areaCounts[rawArea] = (areaCounts[rawArea] ?? 0) + 1;
      final byDist = distCountsByArea.putIfAbsent(rawArea, () => <String, int>{});
      byDist[rawDist] = (byDist[rawDist] ?? 0) + 1;
    }

    final topAreas = _topKeysByCount(areaCounts, 6);
    for (final f in facilities) {
      final fId = f['id'].toString();
      final rawArea = _pickGroupingLabel(
        f,
        const ['plant', 'lineName', 'area', 'department'],
        fallback: 'Main Area',
      );
      final rawDist = _pickGroupingLabel(
        f,
        const ['equipmentType', 'panelName', 'meterGroup', 'category'],
        fallback: 'Distribution',
      );
      final areaLabel = topAreas.contains(rawArea) ? rawArea : 'Other Areas';
      final topDist = _topKeysByCount(distCountsByArea[rawArea] ?? const <String, int>{}, 5);
      final distLabel = topDist.contains(rawDist) ? rawDist : 'Other Distribution';
      final areaKey = _slug(areaLabel);
      final distKey = _slug('$areaLabel-$distLabel');
      final areaNodeId = 'area_$areaKey';
      final distNodeId = 'dist_$distKey';

      if (!areaTargetsByKey.containsKey(areaNodeId)) {
        areaTargetsByKey[areaNodeId] = <String>[];
        nodes.add({
          'id': areaNodeId,
          'tierId': 'tier_hall',
          'label': areaLabel,
          'deviceId': '',
          'fields': ['P(kW)'],
          'targetIds': areaTargetsByKey[areaNodeId],
          'removed': false
        });
        sourceTargets.add(areaNodeId);
      }

      if (!distributionTargetsByKey.containsKey(distNodeId)) {
        distributionTargetsByKey[distNodeId] = <String>[];
        nodes.add({
          'id': distNodeId,
          'tierId': 'tier_dist_1',
          'label': distLabel,
          'deviceId': '',
          'fields': ['P(kW)'],
          'targetIds': distributionTargetsByKey[distNodeId],
          'removed': false
        });
        areaTargetsByKey[areaNodeId]!.add(distNodeId);
      }

      final meterId = (f['meterId'] ?? '').toString().trim();
      nodes.add({
        'id': fId,
        'tierId': 'tier_equipment',
        'master_facility_id': fId,
        'label': _bestFacilityLabel(f),
        'deviceId': meterId.isEmpty ? fId : meterId,
        'fields': ['P(kW)'],
        'targetIds': <String>[],
        'removed': false
      });
      distributionTargetsByKey[distNodeId]!.add(fId);
    }
    return {'tiers': tiers, 'nodes': nodes};
  }

  static String _pickGroupingLabel(
    Map src,
    List<String> keys, {
    required String fallback,
  }) {
    for (final k in keys) {
      final v = src[k];
      if (v != null) {
        final s = _cleanLabel(v.toString());
        if (_isMeaningfulLabel(s)) return s;
      }
    }
    return fallback;
  }

  static String _slug(String text) {
    final base = text.toLowerCase().trim();
    final replaced = base.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final squashed = replaced.replaceAll(RegExp(r'_+'), '_');
    return squashed.replaceAll(RegExp(r'^_|_$'), '');
  }

  static Set<String> _topKeysByCount(Map<String, int> counts, int maxItems) {
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    if (entries.length <= maxItems) return entries.map((e) => e.key).toSet();
    return entries.take(maxItems).map((e) => e.key).toSet();
  }

  static String _cleanLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    // Collapse whitespace for cleaner display.
    return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }

  static bool _isMeaningfulLabel(String v) {
    if (v.trim().isEmpty) return false;
    final lower = v.trim().toLowerCase();
    const invalid = {
      '-',
      '--',
      'n/a',
      'na',
      'none',
      'null',
      'undefined',
      '(blank)',
      'blank',
      'unknown',
      '.',
    };
    return !invalid.contains(lower);
  }
}
