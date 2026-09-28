import 'dart:async';
import 'package:http/http.dart' as http;

import 'package:smartmachine365/services/app_config.dart';
import '/flutter_flow/flutter_flow_util.dart';

/// One pin on the group dashboard's map — "a pin is a lot": each one's
/// [displayName] is also the plant name its own dashboard and settings page
/// are reached by (`?plant=<displayName>`).
class GroupPin {
  const GroupPin({required this.key, required this.displayName});
  final String key;
  final String displayName;
}

/// Reads the group's own pin list, the same way the sidebar needs it to
/// build one nav entry per pin. Kept separate from kanban_dashboard_widget.dart
/// so the side nav doesn't need that whole widget's state to ask this one
/// question.
class GroupPinsService {
  GroupPinsService._();

  static const _peccBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/plant-energy-command-center';
  static const _settingsUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings';

  static List<GroupPin>? _cache;
  static DateTime? _cacheTime;
  static const _cacheTtl = Duration(minutes: 2);

  static void clearCache() {
    _cache = null;
    _cacheTime = null;
  }

  /// Loose match ignoring case/spacing — the same lot can be typed "Lot 237",
  /// "LOT237", "lot 237", etc. across saved pins. Used to tell a plant's own
  /// pin apart from its blocks, which are separate entries, not typos of it.
  static bool isSameLot(String a, String b) {
    String key(String v) => v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final ka = key(a);
    return ka.isNotEmpty && ka == key(b);
  }

  /// The current pin list, or [] on any failure — a missing sidebar entry is
  /// far less harmful than a broken side nav.
  static Future<List<GroupPin>> fetchPins({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cache != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < _cacheTtl) {
      return _cache!;
    }
    try {
      final uid = AppStateNotifier.instance.uid ?? '';
      var pins = uid.isNotEmpty ? await _fetchPinsFor(uid) : null;
      // Same fallback kanban_dashboard_widget.dart's _loadPlantPecc already
      // relies on: the signed-in account may have no group doc of its own
      // (e.g. a viewer, not the admin who set the group map up), so fall
      // back to whichever admin most recently published one.
      if (pins == null) {
        final fallbackUid = await _findFallbackAdminUid();
        if (fallbackUid != null && fallbackUid != uid) {
          pins = await _fetchPinsFor(fallbackUid);
        }
      }
      final result = pins ?? const <GroupPin>[];
      _cache = result;
      _cacheTime = DateTime.now();
      return result;
    } catch (_) {
      return _cache ?? const <GroupPin>[];
    }
  }

  /// Null when this uid has no group doc at all, so the caller knows to try
  /// the fallback — distinct from "a group doc with zero pins."
  static Future<List<GroupPin>?> _fetchPinsFor(String uid) async {
    final res = await http
        .get(Uri.parse('$_peccBase/$uid'), headers: AppConfig.headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['exists'] != true) return null;
    final settings = body['settings'] as Map<String, dynamic>?;
    final pins = settings?['pins'] as List<dynamic>?;
    if (pins == null) return const [];
    final seen = <String>{};
    final out = <GroupPin>[];
    for (final raw in pins) {
      if (raw is! Map) continue;
      final key = raw['key']?.toString() ?? '';
      final name = raw['displayName']?.toString().trim() ?? '';
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
      out.add(GroupPin(key: key, displayName: name));
    }
    return out;
  }

  /// Mirrors kanban_dashboard_widget.dart's _findFallbackAdminUid(): the
  /// userId behind the most recently created row in kanban-settings/list.
  static Future<String?> _findFallbackAdminUid() async {
    try {
      final res = await http
          .get(Uri.parse('$_settingsUrl/list'), headers: AppConfig.headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? [];
      for (final raw in data) {
        final t = raw as Map<String, dynamic>;
        final ownerUid = t['userId']?.toString();
        if (ownerUid != null && ownerUid.isNotEmpty) return ownerUid;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
