import 'dart:convert';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/services/app_config.dart';
import '../models/sankey_setting_data.dart';
import '../services/sankey_setting_service.dart';

part 'sankey_setting_state.dart';

/// Number of placeholder rows spawned the first time "+ Add" is tapped on
/// an empty column. Subsequent taps append exactly one row.
const int kSpawnBurst = 1;

int _idCounter = 0;
String _genId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

SankeyNode _emptyNode(SankeyTier tier, int idx) => SankeyNode(
      id: _genId(),
      tierId: tier.id,
      masterFacilityId: '',
      label: tier.label,
      deviceId: '',
      flowValueTag: '',
      fields: const [''],
      targetIds: const [],
    );

/// Build a per-tier map from a flat list of nodes. Each tier gets its own
/// physically separate list. No padding — an empty tier stays empty until
/// the user taps "+ Add".
Map<String, List<SankeyNode>> _buildNodesByTier(
    List<SankeyTier> tiers, List<SankeyNode> rawNodes) {
  final map = <String, List<SankeyNode>>{};
  for (final tier in tiers) {
    map[tier.id] = rawNodes.where((n) => n.tierId == tier.id).toList();
  }
  return map;
}

  class SankeySettingCubit extends Cubit<SankeySettingState> {
  SankeySettingCubit() : super(const SankeySettingInitial());
  bool _isBuildingTemplate = false;
  bool _didSeedGroups = false;

  /// Generates a professional Data Center demo hierarchy.
  void createDemoTemplate() {
    final s = state;
    if (s is! SankeySettingLoaded) return;

    // Simple template requested:
    // Source (1 node) -> 10 devices (direct fan-out)
    final List<SankeyTier> tiers = [
      const SankeyTier(id: 't0', label: 'Source', order: 0),
      const SankeyTier(id: 't1', label: 'Devices', order: 1),
    ];

    final nodes = <SankeyNode>[];

    final source = _emptyNode(tiers[0], 0).copyWith(
      label: 'Main Incomer',
      deviceId: 'MSB',
      flowValueTag: 'P(kW)',
      fields: const ['P(kW)'],
    );

    final activeIds = ['TD8', 'TD9', 'TD9_Sub', 'TD10', 'CM1', 'CM2', 'CA', 'C2', 'C7', 'Chiller'];
    final devices = List.generate(10, (i) {
      final dev = activeIds[i % activeIds.length];
      return _emptyNode(tiers[1], i).copyWith(
        label: dev,
        deviceId: dev,
        flowValueTag: 'P(kW)',
        fields: const ['P(kW)'],
      );
    });

    nodes.add(source.copyWith(targetIds: devices.map((d) => d.id).toList()));
    nodes.addAll(devices);

    final nodesByTier = _buildNodesByTier(tiers, nodes);
    emit(s.copyWith(
      tiers: tiers,
      nodesByTier: nodesByTier,
    ));

    // Automatically trigger a refresh for the newly mapped demo devices
    final demoDeviceIds = nodes
        .map((n) => n.deviceId)
        .where((id) => id.isNotEmpty)
        .toList();
    if (demoDeviceIds.isNotEmpty) {
      refreshDeviceValues(demoDeviceIds);
    }
  }

  /// Renames a hierarchy tier.
  void updateTierLabel(String tierId, String newLabel) {
    final s = state;
    if (s is! SankeySettingLoaded) return;
    
    final newTiers = s.tiers.map((t) {
      if (t.id == tierId) return t.copyWith(label: newLabel);
      return t;
    }).toList();

    emit(s.copyWith(tiers: newTiers));
  }

  void updateTierColor(String tierId, String colorHex) {
    final s = state;
    if (s is! SankeySettingLoaded) return;

    final newTiers = s.tiers.map((t) {
      if (t.id == tierId) return t.copyWith(colorHex: colorHex);
      return t;
    }).toList();

    emit(s.copyWith(tiers: newTiers));
  }

  // ── Load ──────────────────────────────────────────────────────────────────
  Future<void> load() async {
    emit(const SankeySettingLoading());
    try {
      final results = await Future.wait([
        SankeySettingService.getSetting(),
        SankeySettingService.getDeviceList(forceRefresh: true),
        SankeySettingService.getMasterFacilities(),
        SankeySettingService.getEquipmentList(),
      ]);
      final data = results[0] as Map<String, dynamic>;
      final devices = results[1] as List<String>;
      final facilities = results[2] as List<MasterFacilityTemplate>;
      final equipment = results[3] as List<Map<String, String>>;

      final labels = <String, String>{};
      for (final eq in equipment) {
        final id = eq['id']!;
        final name = eq['name']!;
        labels[id] = '($id) $name';
      }

      final facilityDevices = facilities
          .map((f) => f.nodeDeviceId.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      
      final equipmentIds = equipment.map((e) => e['id']!).toSet();

      final allDevices = {...devices, ...facilityDevices, ...equipmentIds}.toList()..sort();

      final tiers = (data['tiers'] as List<dynamic>? ?? [])
          .map((e) => SankeyTier.fromMap(e as Map<String, dynamic>))
          .toList();
      final rawNodes = (data['nodes'] as List<dynamic>? ?? [])
          .map((e) => SankeyNode.fromMap(e as Map<String, dynamic>))
          .toList();
      final nodesByTier = _buildNodesByTier(tiers, rawNodes);
      final loaded = SankeySettingLoaded(
          tiers: tiers, 
          nodesByTier: nodesByTier, 
          devices: allDevices,
          deviceLabels: labels,
      );

      emit(loaded);
      
      // Fetch initial values for already mapped devices
      final mapped = rawNodes.map((n) => n.deviceId).where((id) => id.isNotEmpty).toSet().toList();
      if (mapped.isNotEmpty) refreshDeviceValues(mapped);
    } catch (e) {
      emit(SankeySettingError(e.toString()));
    }
  }


  /// Creates ONE new Source group:
  /// Source -> Tier1 -> Tier2 -> ... -> last tier
  /// Each tier gets exactly ONE row in the chain, so the group is clear and
  /// grows downward when user adds more rows.
  void _appendSourceGroup({
    required SankeySettingLoaded s,
    required Map<String, List<SankeyNode>> map,
    required String label,
  }) {
    if (s.tiers.isEmpty) return;
    final tier0 = s.tiers.first;
    final list = map[tier0.id] ?? const <SankeyNode>[];
    final src = _emptyNode(tier0, list.length).copyWith(label: label);
    map[tier0.id] = [...list, src];
  }

  // ── Tiers ─────────────────────────────────────────────────────────────────
  /// Adds a new tier with an EMPTY row list. The user must tap "+ Add" on
  /// that column to spawn rows (first tap = burst of [kSpawnBurst]).
  void addTier(String label, int order) {
    final s = _loaded;
    if (s == null) return;
    final tier = SankeyTier(id: _genId(), label: label, order: order);
    final newTiers = [...s.tiers, tier]
      ..sort((a, b) => a.order.compareTo(b.order));
    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier);
    newMap[tier.id] = <SankeyNode>[];
    emit(s.copyWith(tiers: newTiers, nodesByTier: newMap));
  }

  void removeTier(String tierId) {
    final s = _loaded;
    if (s == null) return;
    final removedIds = (s.nodesByTier[tierId] ?? const <SankeyNode>[])
        .map((n) => n.id)
        .toSet();
    final newMap = <String, List<SankeyNode>>{};
    s.nodesByTier.forEach((tId, list) {
      if (tId == tierId) return;
      newMap[tId] = list
          .map((n) => n.targetIds.any(removedIds.contains)
              ? n.copyWith(
                  targetIds: n.targetIds
                      .where((id) => !removedIds.contains(id))
                      .toList())
              : n)
          .toList();
    });
    emit(s.copyWith(
      tiers: s.tiers.where((t) => t.id != tierId).toList(),
      nodesByTier: newMap,
    ));
  }

  // ── Nodes ─────────────────────────────────────────────────────────────────
  /// Append rules — per tier, no cross-tier side effects unless noted:
  ///
  ///   SOURCES tier (tier index 0):
  ///     • NO cap — every tap appends ONE new SOURCE GROUP
  ///       (Source -> Tier1 -> ... chain), so it is always clear & separated.
  ///
  ///   DISTRIBUTION tiers (tier index ≥ 1):
  ///     • empty → burst [kSpawnBurst] placeholder rows sekaligus.
  ///     • non-empty → append exactly one row.
  void addNodeToTier(String tierId) {
    final s = _loaded;
    if (s == null) return;

    final tier = s.tierById(tierId);
    if (tier == null) return;

    final tierIdx = s.tiers.indexWhere((t) => t.id == tierId);
    if (tierIdx < 0) return;

    final isSources = tierIdx == 0;
    final existing = s.nodesByTier[tierId] ?? const <SankeyNode>[];

    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier);

    if (isSources) {
      // Sources are added explicitly one by one.
      _appendSourceGroup(
        s: s.copyWith(nodesByTier: newMap),
        map: newMap,
        label: 'Sources (Left)',
      );
    } else {
      // DISTRIBUTION tiers: burst 5 sekaligus pada first add, then 1 per tap
      newMap[tierId] = existing.isEmpty
          ? List<SankeyNode>.generate(kSpawnBurst, (i) => _emptyNode(tier, i))
          : [...existing, _emptyNode(tier, existing.length)];
    }

    emit(s.copyWith(nodesByTier: newMap));
  }

  /// Adds a child row under an explicit parent node (topology-driven).
  /// Used by grouped UI: add Tier N row under a Tier N-1 node inside one Source group.
  void addChildUnder(String parentId, String childTierId) {
    final s = _loaded;
    if (s == null) return;
    final childTier = s.tierById(childTierId);
    if (childTier == null) return;
    final childList = List<SankeyNode>.from(
        s.nodesByTier[childTierId] ?? const <SankeyNode>[]);
    final child = _emptyNode(childTier, childList.length)
        .copyWith(label: childTier.label);
    childList.add(child);

    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..[childTierId] = childList;

    // Attach parent -> child
    for (final entry in newMap.entries) {
      final idx = entry.value.indexWhere((n) => n.id == parentId);
      if (idx >= 0) {
        final list = List<SankeyNode>.from(entry.value);
        final p = list[idx];
        list[idx] = p.copyWith(targetIds: [...p.targetIds, child.id]);
        newMap[entry.key] = list;
        break;
      }
    }

    emit(s.copyWith(nodesByTier: newMap));
  }

  /// Like [addChildUnder] but spawns [kSpawnBurst] children when [isFirst] is
  /// true (i.e. the tier has no rows yet for this source group), then exactly
  /// one child on subsequent taps. All spawned children are attached to [parentId].
  void addChildrenBurstUnder(
      String parentId, String childTierId, bool isFirst) {
    final s = _loaded;
    if (s == null) return;
    final childTier = s.tierById(childTierId);
    if (childTier == null) return;

    final count = isFirst ? kSpawnBurst : 1;
    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..updateAll((_, list) => List<SankeyNode>.from(list));

    final childList =
        List<SankeyNode>.from(newMap[childTierId] ?? const <SankeyNode>[]);

    for (int i = 0; i < count; i++) {
      final child = _emptyNode(childTier, childList.length)
          .copyWith(label: childTier.label);
      childList.add(child);
      newMap[childTierId] = List<SankeyNode>.from(childList);

      // Attach parent → child (all spawned children link to the same parent)
      for (final entry in newMap.entries) {
        final idx = entry.value.indexWhere((n) => n.id == parentId);
        if (idx >= 0) {
          final list = List<SankeyNode>.from(entry.value);
          final p = list[idx];
          list[idx] = p.copyWith(targetIds: [...p.targetIds, child.id]);
          newMap[entry.key] = list;
          break;
        }
      }
    }

    emit(s.copyWith(nodesByTier: newMap));
  }

  void removeNodeById(String nodeId) {
    final s = _loaded;
    if (s == null) return;
    for (final entry in s.nodesByTier.entries) {
      final idx = entry.value.indexWhere((n) => n.id == nodeId);
      if (idx >= 0) {
        removeNodeAt(entry.key, idx);
        return;
      }
    }
  }

  /// Remove semantics diverge by tier:
  ///
  ///   SOURCES tier (index 0) — CASCADE + SHRINK:
  ///     • Source is physically removed from its list.
  ///     • Every child it owned via targetIds is physically removed
  ///       from the next tier too. Sources below shift up.
  ///
  ///   DISTRIBUTION tier (index ≥ 1) — GHOST IN PLACE:
  ///     • The row's content is cleared but it stays in the list with
  ///       `removed = true`. The widget renders a "+ Add" button in
  ///       its slot instead of a normal row.
  ///     • id + parent targetIds link stay intact so alignment holds
  ///       and the user can restore the slot later with [restoreNodeAt].
  ///
  /// UI is expected to gate this call behind a confirmation dialog.
  void removeNodeAt(String tierId, int rowIdx) {
    final s = _loaded;
    if (s == null) return;
    final sourceList = s.nodesInTier(tierId);
    if (rowIdx < 0 || rowIdx >= sourceList.length) return;

    final tierIdx = s.tiers.indexWhere((t) => t.id == tierId);
    if (tierIdx < 0) return;
    final isSources = tierIdx == 0;

    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..updateAll((_, list) => List<SankeyNode>.from(list));

    if (isSources) {
      // ── TYPE 1: SOURCES (PHYSICAL CASCADE) ──────────────────────────────
      final sources = List<SankeyNode>.from(sourceList);
      final removedNode = sources.removeAt(rowIdx);
      final killIds = <String>{removedNode.id};
      final queue = <String>[...removedNode.targetIds];

      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        if (!killIds.add(current)) continue;
        for (final entry in newMap.entries) {
          final target = entry.value.firstWhere((n) => n.id == current,
              orElse: () => const SankeyNode(id: '', tierId: '', label: '', deviceId: ''));
          if (target.id.isNotEmpty) queue.addAll(target.targetIds);
        }
      }

      for (final entry in newMap.entries) {
        newMap[entry.key] = entry.value
            .where((n) => !killIds.contains(n.id))
            .map((n) => n.copyWith(targetIds: n.targetIds.where((id) => !killIds.contains(id)).toList()))
            .toList();
      }
      newMap[tierId] = sources;
    } else {
      // ── TYPE 2: DISTRIBUTION (GHOST IN PLACE) ────────────────────────────
      final list = List<SankeyNode>.from(sourceList);
      final target = list[rowIdx];
      if (target.removed) return;

      final updatedList = newMap[tierId]!;
      updatedList[rowIdx] = target.copyWith(removed: true);
    }

    emit(s.copyWith(nodesByTier: newMap));
  }

  /// Un-ghosts the slot at [rowIdx] of [tierId] so the widget renders
  /// it as a normal empty row again. User can then fill in device /
  /// data mapping. No-op if the slot isn't currently a ghost.
  void restoreNodeAt(String tierId, int rowIdx) {
    final s = _loaded;
    if (s == null) return;
    final list =
        List<SankeyNode>.from(s.nodesByTier[tierId] ?? const <SankeyNode>[]);
    if (rowIdx < 0 || rowIdx >= list.length) return;
    if (!list[rowIdx].removed) return;
    list[rowIdx] = list[rowIdx].copyWith(removed: false);
    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..[tierId] = list;
    emit(s.copyWith(nodesByTier: newMap));
  }

  // Tier-local coordinate mutators
  void updateNodeAt(String tierId, int rowIdx,
      {String? label, String? deviceId, String? colorHex}) {
    final s = _loaded;
    if (s == null) return;
    final list =
        List<SankeyNode>.from(s.nodesByTier[tierId] ?? const <SankeyNode>[]);
    if (rowIdx < 0 || rowIdx >= list.length) return;
    list[rowIdx] = list[rowIdx].copyWith(
      label: label,
      deviceId: deviceId,
      colorHex: colorHex,
    );
    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..[tierId] = list;
    emit(s.copyWith(nodesByTier: newMap));

    if (deviceId != null && deviceId.isNotEmpty) {
      refreshDeviceValues([deviceId]);
    }
  }

  void updateNodeFieldAt(
      String tierId, int rowIdx, int fieldIdx, String value) {
    final s = _loaded;
    if (s == null) return;
    final list =
        List<SankeyNode>.from(s.nodesByTier[tierId] ?? const <SankeyNode>[]);
    if (rowIdx < 0 || rowIdx >= list.length) return;
    final n = list[rowIdx];
    final fields = List<String>.from(n.fields);
    while (fields.length <= fieldIdx) {
      fields.add('');
    }
    fields[fieldIdx] = value;
    final primary = fields.firstWhere(
      (f) => f.trim().isNotEmpty,
      orElse: () => n.flowValueTag,
    );
    list[rowIdx] = n.copyWith(fields: fields, flowValueTag: primary);
    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..[tierId] = list;
    emit(s.copyWith(nodesByTier: newMap));
  }

  /// Appends an empty field slot to the node at [rowIdx] in [tierId].
  void addNodeField(String tierId, int rowIdx) {
    final s = _loaded;
    if (s == null) return;
    final list =
        List<SankeyNode>.from(s.nodesByTier[tierId] ?? const <SankeyNode>[]);
    if (rowIdx < 0 || rowIdx >= list.length) return;
    final n = list[rowIdx];
    final fields = List<String>.from(n.fields)..add('');
    list[rowIdx] = n.copyWith(fields: fields);
    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..[tierId] = list;
    emit(s.copyWith(nodesByTier: newMap));
  }

  /// Removes the field slot at [fieldIdx] from the node at [rowIdx] in [tierId].
  /// If only one slot remains, the slot is cleared instead of removed.
  void removeNodeField(String tierId, int rowIdx, int fieldIdx) {
    final s = _loaded;
    if (s == null) return;
    final list =
        List<SankeyNode>.from(s.nodesByTier[tierId] ?? const <SankeyNode>[]);
    if (rowIdx < 0 || rowIdx >= list.length) return;
    final n = list[rowIdx];
    final fields = List<String>.from(n.fields);
    if (fields.length <= 1) {
      fields[0] = '';
    } else if (fieldIdx >= 0 && fieldIdx < fields.length) {
      fields.removeAt(fieldIdx);
    }
    list[rowIdx] = n.copyWith(fields: fields);
    final newMap = Map<String, List<SankeyNode>>.from(s.nodesByTier)
      ..[tierId] = list;
    emit(s.copyWith(nodesByTier: newMap));
  }

  Future<void> loadTemplateFromMasterFacility() async {
    final s = _loaded;
    if (s == null) return;
    if (_isBuildingTemplate) {
      throw Exception('Template build is already running. Please wait.');
    }
    if (s.allNodes.isNotEmpty) {
      throw Exception(
          'Sankey template already exists. Clear the current configuration before rebuilding.');
    }
    _isBuildingTemplate = true;
    try {
      final facilities = await SankeySettingService.getMasterFacilities();
      if (facilities.isEmpty) {
        throw Exception(
            'Master Facility is empty. Add data before building template.');
      }

      final tiers = [
        SankeyTier(id: _genId(), label: 'Main Source', order: 0),
        SankeyTier(id: _genId(), label: 'Data Hall', order: 1),
        SankeyTier(id: _genId(), label: 'Distribution Tier 1', order: 2),
        SankeyTier(id: _genId(), label: 'Distribution Tier 2', order: 3),
        SankeyTier(id: _genId(), label: 'Equipment', order: 4),
      ];

      final sourceTier = tiers[0];
      final hallTier = tiers[1];
      final distTier1 = tiers[2];
      final distTier2 = tiers[3];
      final equipTier = tiers[4];

      // ── helpers ─────────────────────────────────────────────────────────
      String norm(String raw) =>
          raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

      String pickHall(MasterFacilityTemplate f) {
        final v = f.factory.trim();
        return v.isNotEmpty ? v : 'Data Hall';
      }

      String pickCategory(MasterFacilityTemplate f) {
        final text = f.nodeLabel.toLowerCase();
        if (text.contains('crac')) return 'CRAC';
        if (text.contains('pdu')) return 'PDU';
        if (text.contains('inrak') || text.contains('rack')) return 'InRack';
        if (text.contains('ups')) return 'UPS';
        if (text.contains('panel') ||
            text.contains('mdb') ||
            text.contains('sdp')) return 'Panel';
        if (text.contains('server')) return 'Server Room';
        if (text.contains('compressor') ||
            text.contains('chiller') ||
            text.contains('ancillary')) return 'Ancillary';
        return 'Other';
      }

      String categoryLane(String cat) {
        switch (cat) {
          case 'CRAC':
            return 'CRACs';
          case 'PDU':
            return 'PDUs';
          case 'InRack':
            return 'InRaks';
          case 'UPS':
            return 'UPS Units';
          case 'Panel':
            return 'Panels';
          case 'Server Room':
            return 'Server Room';
          case 'Ancillary':
            return 'Ancillary Power';
          default:
            return 'Others';
        }
      }

      SankeyNode mkNode({
        required String id,
        required SankeyTier tier,
        required String label,
        String deviceId = '',
        String masterFacilityId = '',
        List<String> targetIds = const [],
      }) =>
          SankeyNode(
            id: id,
            tierId: tier.id,
            masterFacilityId: masterFacilityId,
            label: label,
            deviceId: deviceId,
            flowValueTag: 'P(kW)',
            fields: const ['P(kW)'],
            targetIds: targetIds,
            removed: false,
          );

      // ── Group facilities by hall (factory) ──────────────────────────────
      final hallGroups = <String, List<MasterFacilityTemplate>>{};
      for (final f in facilities) {
        hallGroups.putIfAbsent(pickHall(f), () => []).add(f);
      }

      // Sort halls alphabetically; cap at 5 source groups for sanity
      final hallKeys = (hallGroups.keys.toList()..sort()).take(5).toList();

      final newMap = <String, List<SankeyNode>>{
        for (final t in tiers) t.id: <SankeyNode>[],
      };

      for (final hallKey in hallKeys) {
        final hallFacilities = hallGroups[hallKey]!;
        final repFacilityId = hallFacilities.first.id;

        final srcId = 'src_${norm(hallKey)}';
        final hallId = 'hall_${norm(hallKey)}';

        // Group within this hall by equipment category
        final catGroups = <String, List<MasterFacilityTemplate>>{};
        for (final f in hallFacilities) {
          catGroups.putIfAbsent(pickCategory(f), () => []).add(f);
        }

        final dist1Ids = <String>[];

        for (final catKey in (catGroups.keys.toList()..sort())) {
          final catFacilities = catGroups[catKey]!;
          final catRepId = catFacilities.first.id;

          final d1Id = 'd1_${norm(hallKey)}_${norm(catKey)}';
          final d2Id = 'd2_${norm(hallKey)}_${norm(catKey)}';
          dist1Ids.add(d1Id);

          // Equipment nodes — only devices with a real non-empty meterId
          final equipIds = <String>[];
          final seenDevices = <String>{};
          for (final f in catFacilities) {
            final deviceId = f.nodeDeviceId.trim();
            if (deviceId.isEmpty) continue; // skip blank meters
            if (!seenDevices.add(deviceId)) continue; // skip duplicates
            final eId = 'eq_${norm(deviceId)}';
            equipIds.add(eId);
            newMap[equipTier.id]!.add(mkNode(
              id: eId,
              tier: equipTier,
              label: f.nodeLabel,
              deviceId: deviceId,
              masterFacilityId: f.id,
            ));
          }

          // Distribution Tier 2: lane grouping → equipment
          newMap[distTier2.id]!.add(mkNode(
            id: d2Id,
            tier: distTier2,
            label: '$hallKey ${categoryLane(catKey)}',
            masterFacilityId: catRepId,
            targetIds: equipIds,
          ));

          // Distribution Tier 1: category group → Tier 2
          newMap[distTier1.id]!.add(mkNode(
            id: d1Id,
            tier: distTier1,
            label: '$hallKey $catKey',
            masterFacilityId: catRepId,
            targetIds: [d2Id],
          ));
        }

        // Data Hall → Tier 1 categories
        newMap[hallTier.id]!.add(mkNode(
          id: hallId,
          tier: hallTier,
          label: hallKey,
          masterFacilityId: repFacilityId,
          targetIds: dist1Ids,
        ));

        // Source → Data Hall (1 source per hall = 1 independent source group)
        newMap[sourceTier.id]!.add(mkNode(
          id: srcId,
          tier: sourceTier,
          label: '$hallKey Incomer',
          masterFacilityId: repFacilityId,
          targetIds: [hallId],
        ));
      }

      emit(s.copyWith(tiers: tiers, nodesByTier: newMap));
    } finally {
      _isBuildingTemplate = false;
    }
  }

  // ── Save ──────────────────────────────────────────────────────────────────
  Future<void> save() async {
    final s = _loaded;
    if (s == null) return;
    emit(SankeySettingSaving(
        tiers: s.tiers, nodesByTier: s.nodesByTier, devices: s.devices));
    try {
      await SankeySettingService.saveSetting(tiers: s.tiers, nodes: s.allNodes);
      emit(SankeySettingSaved(
          tiers: s.tiers, nodesByTier: s.nodesByTier, devices: s.devices));
      await Future.delayed(const Duration(seconds: 1));
      emit(SankeySettingLoaded(
          tiers: s.tiers, nodesByTier: s.nodesByTier, devices: s.devices));
    } catch (e) {
      emit(SankeySettingSaveError(
        message: e.toString(),
        tiers: s.tiers,
        nodesByTier: s.nodesByTier,
        devices: s.devices,
      ));
      await Future.delayed(const Duration(seconds: 2));
      emit(SankeySettingLoaded(
          tiers: s.tiers, nodesByTier: s.nodesByTier, devices: s.devices));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  SankeySettingLoaded? get _loaded {
    final s = state;
    if (s is SankeySettingLoaded) return s;
    if (s is SankeySettingSaving) {
      return SankeySettingLoaded(
          tiers: s.tiers, nodesByTier: s.nodesByTier, devices: s.devices);
    }
    return null;
  }

  // ── Live Data Fetching ───────────────────────────────────────────────────
  static const String _influxBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/realtime';
  static const String _energyBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/total';

  Future<void> refreshDeviceValues(List<String> deviceIds) async {
    final s = _loaded;
    if (s == null || deviceIds.isEmpty) return;

    final fields = ['P(kW)', 'PeakDemand', 'Edel', 'Erec', 'Eapp', 'daily_kWh', 'monthly_kWh', 'yearly_kWh'];
    
    // Create a copy of existing values
    final newValues = Map<String, Map<String, double>>.from(s.deviceValues);

    // Fetch in parallel for speed
    await Future.wait(deviceIds.map((devId) async {
      if (devId.isEmpty) return;
      
      final devMap = Map<String, double>.from(newValues[devId] ?? {});
      await Future.wait(fields.map((field) async {
        final val = await _fetchValue(devId, field);
        devMap[field] = val;
      }));
      newValues[devId] = devMap;
    }));

    if (state is SankeySettingLoaded) {
      emit((state as SankeySettingLoaded).copyWith(deviceValues: newValues));
    }
  }

  static Future<double> _fetchValue(String deviceId, String field) async {
    if (deviceId.isEmpty || field.isEmpty) return 0.0;
    if (field == 'daily_kWh' || field == 'monthly_kWh' || field == 'yearly_kWh') {
      return _fetchTotal(deviceId, field.replaceAll('_kWh', ''));
    }
    return _fetchInflux(deviceId, field);
  }

  static Future<double> _fetchInflux(String deviceId, String field) async {
    try {
      final res = await http.get(Uri.parse('$_influxBase/$deviceId?fields=$field'), headers: AppConfig.headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return 0.0;
      final body = json.decode(res.body);
      final List<dynamic> list = body is Map
          ? ((body['value'] ?? body['data'] ?? []) as List<dynamic>)
          : (body is List ? body : []);
      for (final item in list) {
        if (item is! Map) continue;
        final f = (item['field'] ?? item['Field'] ?? '').toString();
        if (f == field) return (item['value'] ?? item['Value'] ?? 0).toDouble();
      }
    } catch (_) {}
    return 0.0;
  }

  static Future<double> _fetchTotal(String deviceId, String period) async {
    try {
      final res = await http.get(Uri.parse('$_energyBase/$deviceId'), headers: AppConfig.headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return 0.0;
      final List<dynamic> list = json.decode(res.body);
      for (final item in list) {
        if (item is! Map) continue;
        if ((item['period'] ?? '').toString() == period) {
          return (item['total_energy'] ?? 0).toDouble();
        }
      }
    } catch (_) {}
    return 0.0;
  }
}
