import 'dart:convert';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/auth/firebase_auth/auth_util.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'integration_config_models.dart';

const _apiBaseFallback = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

// ── States ────────────────────────────────────────────────────────────────────
abstract class IntegrationConfigState {}

class IntegrationConfigInitial extends IntegrationConfigState {}

class IntegrationConfigLoading extends IntegrationConfigState {}

class IntegrationConfigLoaded extends IntegrationConfigState {
  final List<ClientConfig> clients;
  final String selectedId;
  IntegrationConfigLoaded({required this.clients, required this.selectedId});

  ClientConfig? get selected =>
      clients.where((c) => c.id == selectedId).firstOrNull;

  IntegrationConfigLoaded copyWith({
    List<ClientConfig>? clients,
    String? selectedId,
  }) =>
      IntegrationConfigLoaded(
        clients: clients ?? this.clients,
        selectedId: selectedId ?? this.selectedId,
      );
}

class IntegrationConfigError extends IntegrationConfigState {
  final String message;
  IntegrationConfigError(this.message);
}

class IntegrationConfigSaving extends IntegrationConfigState {
  final List<ClientConfig> clients;
  final String selectedId;
  IntegrationConfigSaving({required this.clients, required this.selectedId});
}

class IntegrationConfigSaved extends IntegrationConfigState {
  final List<ClientConfig> clients;
  final String selectedId;
  IntegrationConfigSaved({required this.clients, required this.selectedId});
}

class IntegrationConfigTestingConn extends IntegrationConfigState {
  final List<ClientConfig> clients;
  final String selectedId;
  final String connType; // 'influx' | 'mysql'
  IntegrationConfigTestingConn({
    required this.clients,
    required this.selectedId,
    required this.connType,
  });
}

class IntegrationConfigConnTested extends IntegrationConfigState {
  final List<ClientConfig> clients;
  final String selectedId;
  final String connType;
  final bool ok;
  final int? ms;
  IntegrationConfigConnTested({
    required this.clients,
    required this.selectedId,
    required this.connType,
    required this.ok,
    this.ms,
  });
}

// ── Cubit ─────────────────────────────────────────────────────────────────────
class IntegrationConfigCubit extends Cubit<IntegrationConfigState> {
  IntegrationConfigCubit() : super(IntegrationConfigInitial());


  Future<void> load() async {
    emit(IntegrationConfigLoading());
    try {
      final response = await http.get(
        Uri.parse('$_apiBaseFallback/integrationConfig/loadConfigs'),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      // A customer site lists only its own client — Thong Guan's site never
      // shows the demo config, and demo's never shows Thong Guan's.
      final List<dynamic> list = (jsonDecode(response.body) as List)
          .where((m) => AppConfig.showsClient((m['id'] ?? '').toString()))
          .toList();

      // Load plants from General Factory Setting
      final plants = await _loadPlantsFromFactory();

      final clients = await Future.wait(list.map((m) async {
        final client = ClientConfig.fromMap(m['id'] as String, Map<String, dynamic>.from(m));
        final token = await _loadTokenFromApi(client.id);
        return client.copyWith(
          influx: client.influx.copyWith(token: token),
          plants: client.plants.isNotEmpty ? client.plants : plants,
        );
      }));
      emit(IntegrationConfigLoaded(
        clients: clients,
        selectedId: clients.isNotEmpty ? clients.first.id : '',
      ));
    } catch (e) {
      emit(IntegrationConfigError('Failed to load: $e'));
    }
  }

  Future<List<String>> _loadPlantsFromFactory() async {
    try {
      final response = await http.get(
        Uri.parse('${AppConfig.apiBase}/factory'),
        headers: AppConfig.headers,
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((f) => f['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<String> _loadTokenFromApi(String clientId) async {
    try {
      final response = await http.get(
        Uri.parse('$_apiBaseFallback/integrationConfig/loadSecret/$clientId/influx'),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['token'] ?? '';
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveInfluxToken(String clientId, String token) async {
    await http.post(
      Uri.parse('$_apiBaseFallback/integrationConfig/saveSecret'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'clientId': clientId, 'type': 'influx', 'secret': {'token': token}}),
    ).timeout(const Duration(seconds: 10));
  }

  void select(String id) {
    final st = state;
    if (st is IntegrationConfigLoaded) {
      emit(st.copyWith(selectedId: id));
    }
  }

  Future<void> save(ClientConfig updated) async {
    final st = state;
    if (st is! IntegrationConfigLoaded) return;

    emit(IntegrationConfigSaving(clients: st.clients, selectedId: st.selectedId));
    try {
      final now = _timestamp();
      final entry = HistoryEntry(
        ts: now,
        who: 'Admin',
        msg: 'Config saved & deployed',
      );
      final withHistory = updated.copyWith(
        history: [entry, ...updated.history],
        checklist: updated.checklist.copyWith(
          influx: updated.influx.connected,
          mysql: updated.mysql.connected,
          stag: updated.siteTags.isNotEmpty,
          live: updated.influx.connected,
        ),
        firebase: updated.firebase.copyWith(
          secretSet: updated.firebase.secretSet,
        ),
      );
      await http.post(
        Uri.parse('$_apiBaseFallback/integrationConfig/saveConfig'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'clientId': updated.id, 'data': withHistory.toMap()}),
      ).timeout(const Duration(seconds: 15));

      await http.post(
        Uri.parse('$_apiBaseFallback/integrationConfig/setActive'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'clientId': updated.id,
          'clientName': updated.name,
          'siteTags': updated.siteTags.map((t) => t.toMap()).toList(),
        }),
      ).timeout(const Duration(seconds: 10));

      // Refresh AppConfig so all modules immediately use new apiBaseUrl
      await AppConfig.refresh();

      // Auto-sync discovered devices to Master Facility
      _syncToFacility(updated.id);

      final clients = st.clients.map((c) => c.id == updated.id ? withHistory : c).toList();
      emit(IntegrationConfigSaved(clients: clients, selectedId: st.selectedId));

      await Future.delayed(const Duration(milliseconds: 200));
      emit(IntegrationConfigLoaded(clients: clients, selectedId: st.selectedId));
    } catch (e) {
      emit(IntegrationConfigError('Failed to save: $e'));
    }
  }

  Future<void> saveMysqlPassword(String clientId, String password) async {
    await http.post(
      Uri.parse('$_apiBaseFallback/integrationConfig/saveSecret'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'clientId': clientId, 'type': 'mysql', 'secret': {'password': password}}),
    ).timeout(const Duration(seconds: 10));
  }

  Future<void> saveFirebaseSecret(String clientId, String serviceAccountJson) async {
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(serviceAccountJson) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Service Account JSON tidak valid. Paste full JSON dari Firebase Console → Service Accounts → Generate new private key.');
    }
    if (parsed['private_key'] == null || parsed['client_email'] == null) {
      throw Exception('JSON tidak lengkap. Pastikan berisi private_key dan client_email.');
    }
    await http.post(
      Uri.parse('$_apiBaseFallback/integrationConfig/saveSecret'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'clientId': clientId, 'type': 'firebase', 'secret': parsed}),
    ).timeout(const Duration(seconds: 10));
  }

  Future<void> testConnection(
    ClientConfig client,
    String connType, {
    String mysqlPassword = '',
  }) async {
    final st = state;
    if (st is! IntegrationConfigLoaded) return;

    emit(IntegrationConfigTestingConn(
      clients: st.clients,
      selectedId: st.selectedId,
      connType: connType,
    ));

    final now = _timestamp();
    final isInflux = connType == 'influx';

    bool ok = false;
    int? ms;

    try {
      final response = await http.post(
        Uri.parse('$_apiBaseFallback/integrationConfig/test'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'clientId': client.id,
          'type': connType,
          if (!isInflux) 'database': client.mysql.database,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        ok = body['ok'] == true;
        ms = body['latencyMs'] as int?;
      }
    } catch (_) {
      ok = false;
    }

    final updatedInflux = isInflux
        ? client.influx.copyWith(connected: ok, latencyMs: ms, lastCheck: now)
        : client.influx;
    final updatedMysql = !isInflux
        ? client.mysql.copyWith(connected: ok, latencyMs: ms, lastCheck: now)
        : client.mysql;

    final logEntry = HealthLogEntry(
      time: now,
      level: ok ? 'ok' : 'err',
      message: ok
          ? '${isInflux ? 'InfluxDB' : 'MySQL'} connection OK — ${ms}ms'
          : '${isInflux ? 'InfluxDB' : 'MySQL'} connection failed — host not configured',
    );

    final updatedClient = client.copyWith(
      influx: updatedInflux,
      mysql: updatedMysql,
      checklist: client.checklist.copyWith(
        influx: updatedInflux.connected,
        mysql: updatedMysql.connected,
      ),
      healthLog: [logEntry, ...client.healthLog],
    );

    final clients = st.clients.map((c) => c.id == client.id ? updatedClient : c).toList();

    try {
      await http.post(
        Uri.parse('$_apiBaseFallback/integrationConfig/saveConfig'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'clientId': client.id,
          'data': {
            'influx': updatedInflux.toMap(),
            'mysql': updatedMysql.toMap(),
            'checklist': updatedClient.checklist.toMap(),
            'healthLog': updatedClient.healthLog.map((l) => l.toMap()).toList(),
          },
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}

    emit(IntegrationConfigConnTested(
      clients: clients,
      selectedId: st.selectedId,
      connType: connType,
      ok: ok,
      ms: ms,
    ));

    await Future.delayed(const Duration(milliseconds: 100));
    emit(IntegrationConfigLoaded(clients: clients, selectedId: st.selectedId));
  }

  Future<void> addClient(ClientConfig newClient) async {
    final st = state;
    if (st is! IntegrationConfigLoaded) return;

    try {
      final data = newClient.toMap();
      await http.post(
        Uri.parse('$_apiBaseFallback/integrationConfig/saveConfig'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'clientId': newClient.id, 'data': data}),
      ).timeout(const Duration(seconds: 15));
      final clients = [...st.clients, newClient];
      emit(IntegrationConfigLoaded(clients: clients, selectedId: newClient.id));
    } catch (e) {
      emit(IntegrationConfigError('Failed to add client: $e'));
    }
  }

  // ── Client Registry (pending clients pick-list) ───────────────────────────
  Future<List<Map<String, String>>> loadRegistry() async {
    try {
      final res = await http
          .get(Uri.parse('$_apiBaseFallback/integrationConfig/registry'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final List data = jsonDecode(res.body);
      return data
          .map((e) => {
                'id': (e['id'] ?? '').toString(),
                'name': (e['name'] ?? '').toString(),
              })
          .where((e) => e['id']!.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> addRegistryEntry(String id, String name) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_apiBaseFallback/integrationConfig/registry'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'id': id, 'name': name}),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> removeRegistryEntry(String id) async {
    try {
      await http
          .delete(Uri.parse('$_apiBaseFallback/integrationConfig/registry/$id'))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // best-effort
    }
  }

  // Fire-and-forget: auto-sync InfluxDB devices to Master Facility after save
  void _syncToFacility(String clientId) {
    final uid = currentUserUid;
    if (uid.isEmpty) return;
    http.post(
      Uri.parse('${AppConfig.dataApiBase}/discoveryDevice/syncToFacility'),
      headers: {'Content-Type': 'application/json', 'x-client-id': clientId},
      body: jsonEncode({'uid': uid}),
    ).timeout(const Duration(seconds: 30)).catchError((_) => http.Response('', 0));
  }

  Future<void> removeClient(String clientId) async {
    final st = state;
    if (st is! IntegrationConfigLoaded) return;

    try {
      await http.delete(
        Uri.parse('$_apiBaseFallback/integrationConfig/deleteConfig/$clientId'),
      ).timeout(const Duration(seconds: 15));
      final clients = st.clients.where((c) => c.id != clientId).toList();
      final newSelected = clients.isNotEmpty ? clients.first.id : '';
      emit(IntegrationConfigLoaded(clients: clients, selectedId: newSelected));
    } catch (e) {
      emit(IntegrationConfigError('Failed to remove client: $e'));
    }
  }

  String _timestamp() {
    final now = DateTime.now();
    return '${now.year}-${_p(now.month)}-${_p(now.day)} '
        '${_p(now.hour)}:${_p(now.minute)}';
  }

  String _p(int n) => n.toString().padLeft(2, '0');
}
