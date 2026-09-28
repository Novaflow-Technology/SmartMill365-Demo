import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/utils/leak_probe.dart';

/// Time series data point for historical trends
class TimeSeriesPoint {
  final DateTime time;
  final String field;
  final String measurement;
  final double value;

  TimeSeriesPoint({
    required this.time,
    required this.field,
    required this.measurement,
    required this.value,
  });

  /// Returns null instead of throwing when a row is unusable (missing or
  /// unparseable `time`, non-numeric `value`). InfluxDB can return rows with a
  /// null timestamp, and one such row used to throw out of the enclosing
  /// `.map().toList()` — discarding the entire batch and leaving the trend
  /// charts permanently empty.
  static TimeSeriesPoint? tryFromJson(dynamic json) {
    if (json is! Map) return null;

    final rawTime = json['time'];
    if (rawTime is! String) return null;
    final time = DateTime.tryParse(rawTime);
    if (time == null) return null;

    final rawValue = json['value'];
    final value = rawValue is num
        ? rawValue.toDouble()
        : double.tryParse(rawValue?.toString() ?? '');
    if (value == null) return null;

    return TimeSeriesPoint(
      time: time,
      field: json['field']?.toString() ?? '',
      measurement: json['measurement']?.toString() ?? '',
      value: value,
    );
  }
}

/// Sensor data structure returned by InfluxDB
class SensorData {
  final Map<String, dynamic> current;
  final Map<String, dynamic> voltage;
  final Map<String, dynamic> power;
  final Map<String, dynamic> energy;

  SensorData({
    required this.current,
    required this.voltage,
    required this.power,
    required this.energy,
  });

  factory SensorData.empty() {
    return SensorData(
      current: {'value': 'No Data'},
      voltage: {'value': 'No Data'},
      power: {'value': 'No Data'},
      energy: {'value': 'No Data'},
    );
  }
}

/// Service for fetching real-time data from InfluxDB API
class InfluxDBService {
  String get baseUrl =>
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb';
  static const String _ui7Base = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (AppConfig.clientId.isNotEmpty) 'x-client-id': AppConfig.clientId,
      };
  final Duration pollingInterval;
  final Function(SensorData) onDataReceived;
  final Function(String)? onError;

  Timer? _pollingTimer;
  Timer? _timeSeriesTimer;

  /// One client for the life of the service. http.get() builds and tears down a
  /// client per call; reusing one keeps a single connection pool and gives
  /// dispose() something to close, which aborts any request still in flight
  /// instead of leaving it to complete against a dead service.
  final http.Client _client = http.Client();
  String? _currentDeviceId;
  bool _isDisposed = false;
  bool isConnected = false;

  // A realtime fetch can take far longer than the 5s poll interval (10s
  // timeout, plus up to 22s more on the fallback path). Without these guards
  // every slow tick stacked another in-flight request — and its response
  // buffer — on top of the last, which is what made the tab's memory climb
  // without bound. One request of each kind at a time.
  // These skip a tick while the previous request is still running. They are not
  // a rate limit: nothing is queued and nothing is dropped permanently — the
  // next tick simply tries again. The timestamps make the guard self-healing:
  // if a request somehow never settles, the flag is treated as stale after
  // _inFlightMaxAge and polling resumes, so live data can never stall forever.
  bool _realtimeInFlight = false;
  DateTime? _realtimeStartedAt;
  bool _timeSeriesInFlight = false;
  DateTime? _timeSeriesStartedAt;

  static const Duration _inFlightMaxAge = Duration(seconds: 45);

  bool _blocked(bool inFlight, DateTime? startedAt) {
    if (!inFlight) return false;
    if (startedAt == null) return true;
    return DateTime.now().difference(startedAt) < _inFlightMaxAge;
  }

  // Cache for timeseries data
  List<TimeSeriesPoint> _cachedTimeSeries = [];

  InfluxDBService({
    required this.pollingInterval,
    required this.onDataReceived,
    this.onError,
  }) {
    LeakProbe.register('InfluxDBService');
  }

  /// Start polling for real-time data
  void startPolling(String deviceId) {
    _currentDeviceId = deviceId;
    // Cancel first, always. Calling startPolling twice must never leave two
    // poll timers behind — that is the root cause the leak brief describes.
    _stopPolling();
    assert(_pollingTimer == null && _timeSeriesTimer == null,
        'startPolling left a live timer behind');

    // Fetch immediately
    _fetchRealtimeData();
    // _fetchTimeSeriesData();

    // Poll realtime data at specified interval (e.g., every 5 seconds)
    LeakProbe.register('InfluxDB.pollTimer');
    _pollingTimer = Timer.periodic(pollingInterval, (_) {
      if (!_isDisposed) {
        _fetchRealtimeData();
      }
    });

    // Poll timeseries data less frequently (e.g., every 30 seconds)
    LeakProbe.register('InfluxDB.seriesTimer');
    _timeSeriesTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isDisposed) {
        _fetchTimeSeriesData();
      }
    });
  }

  /// Switch to a different device
  void switchDevice(String newDeviceId) {
    _currentDeviceId = newDeviceId;
    _cachedTimeSeries.clear();
    _fetchRealtimeData();
    // _fetchTimeSeriesData();
  }

  /// Fetch real-time sensor data from InfluxDB (last 5 seconds)
  Future<void> _fetchRealtimeData() async {
    if (_currentDeviceId == null || _isDisposed) return;
    if (_blocked(_realtimeInFlight, _realtimeStartedAt)) return;
    _realtimeInFlight = true;
    _realtimeStartedAt = DateTime.now();
    LeakProbe.tick('InfluxDB.realtimeRequest');

    try {
      // Fetch all fields for comprehensive real-time data
      // final fields = 'Ia,Ib,Ic,Iavg,Vab,Vbc,Vca,Vavg,P(kW),Q(kVAr),S(kVA),PF,Edel,Erec,Eapp';
      const fields =
          'IA,IB,IC,UAB,UBC,UCA,Uavg,P(W),Q(VAR),S(VA),Iavg,Vab,Vbc,Vca,Vavg,P(kW),Q(kVAr),S(kVA),PF,Edel,Erec,Eapp,Freq,PeakDemand';
      final response = await _client
          .get(Uri.parse('$baseUrl/realtime/$_currentDeviceId?fields=$fields'),
              headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (_isDisposed) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        final List<dynamic> data;
        if (decoded is String) {
          data = jsonDecode(decoded);
        } else if (decoded is List) {
          data = decoded;
        } else {
          throw Exception('Unexpected response format');
        }

        if (data.isEmpty) {
          // Fallback for meters that don't publish realtime fields (common in
          // some tenants/devices): use Max Demand 24h service as a proxy for
          // current load so "Energy Details" doesn't show 0/No Data forever.
          final fallback = await _fetchFallbackPowerKw(_currentDeviceId!);
          if (fallback > 0) {
            isConnected = true;
            onDataReceived(SensorData(
              current: {'value': 'Fallback'},
              voltage: {'value': 'Fallback'},
              power: {'P(kW)': fallback, 'source': 'power-load-24h'},
              energy: {'value': 'Fallback'},
            ));
            return;
          }

          isConnected = false;
          onDataReceived(SensorData.empty());
          return;
        }

        isConnected = true;

        // Parse sensor data and embed timeseries within each data map
        final sensorData = _parseSensorData(data);
        onDataReceived(sensorData);
      } else {
        isConnected = false;
        _handleError('Failed to fetch data: ${response.statusCode}');
      }
    } catch (e) {
      isConnected = false;
      _handleError('Error fetching realtime data: $e');
    } finally {
      _realtimeInFlight = false;
      _realtimeStartedAt = null;
    }
  }

  Future<double> _fetchFallbackPowerKw(String deviceId) async {
    try {
      // Prefer current load if available.
      final curRes = await _client
          .get(
            Uri.parse(
                '$_ui7Base/energyDetailsInfluxDb/power-load/current?deviceId=$deviceId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));
      if (curRes.statusCode == 200) {
        final body = jsonDecode(curRes.body);
        if (body is Map && body['power_kw'] != null) {
          final v = body['power_kw'];
          final parsed =
              v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0;
          if (parsed > 0) return parsed;
        }
      }

      // Then fall back to 24h MD series which exists for VDPM002 etc.
      final res = await _client
          .get(
            Uri.parse('$_ui7Base/energyDetails/power-load-24h/$deviceId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 0.0;
      final body = jsonDecode(res.body);
      if (body is! Map) return 0.0;
      final data = body['data'];
      if (data is List && data.isNotEmpty) {
        final last = data.last;
        if (last is Map && last['max_demand_kW'] != null) {
          final v = last['max_demand_kW'];
          final parsed =
              v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0;
          if (parsed > 0) return parsed;
        }
      }
      final stats = body['statistics'];
      if (stats is Map) {
        final v = stats['current_max_demand_kW'] ?? stats['max_demand_kW'];
        final parsed = v is num
            ? v.toDouble()
            : double.tryParse(v?.toString() ?? '') ?? 0.0;
        return parsed;
      }
    } catch (_) {}
    return 0.0;
  }

  /// Fetch time-series data for historical trends (last hour with 1-minute windows)
  Future<void> _fetchTimeSeriesData() async {
    if (_currentDeviceId == null || _isDisposed) return;
    if (_blocked(_timeSeriesInFlight, _timeSeriesStartedAt)) return;
    _timeSeriesInFlight = true;
    _timeSeriesStartedAt = DateTime.now();

    try {
      // Fetch last hour of data with 1-minute aggregation windows
      const fields =
          'IA,IB,IC,UAB,UBC,UCA,Uavg,P(W),Q(VAR),S(VA),Iavg,Vab,Vbc,Vca,Vavg,P(kW),Q(kVAr),S(kVA),PF,Edel,Erec,Eapp,Freq,PeakDemand';
      final response = await _client
          .get(
              Uri.parse(
                  '$baseUrl/timeseries/custom?start=-1h&stop=now()&window_period=1m&machine_ids=$_currentDeviceId&fields=$fields'),
              headers: _headers)
          .timeout(const Duration(seconds: 15));

      if (_isDisposed) return;

      if (response.statusCode == 200) {
        // The endpoint has been seen returning a JSON-encoded string as well as
        // a bare list, so unwrap one level before assuming a list.
        var decoded = jsonDecode(response.body);
        if (decoded is String) decoded = jsonDecode(decoded);

        if (_isDisposed) return;
        if (decoded is List) {
          // Skip unusable rows rather than losing the whole batch to one.
          _cachedTimeSeries = decoded
              .map(TimeSeriesPoint.tryFromJson)
              .whereType<TimeSeriesPoint>()
              .toList();
        } else {
          _handleError('Unexpected timeseries response format');
        }
      } else {
        _handleError('Failed to fetch timeseries: ${response.statusCode}');
      }
    } catch (e) {
      _handleError('Error fetching timeseries data: $e');
    } finally {
      _timeSeriesInFlight = false;
      _timeSeriesStartedAt = null;
    }
  }

  /// Parse raw InfluxDB data into structured sensor data with embedded timeseries
  SensorData _parseSensorData(List<dynamic> rawData) {
    Map<String, dynamic> currentData = {};
    Map<String, dynamic> voltageData = {};
    Map<String, dynamic> powerData = {};
    Map<String, dynamic> energyData = {};

    // Parse real-time values
    for (var item in rawData) {
      final measurement = item['measurement']?.toString().toUpperCase() ?? '';
      final field = item['field']?.toString() ?? '';
      final value = item['value'];

      if (measurement == 'CURRENT') {
        if (field == 'IA') currentData['IA'] = value;
        if (field == 'IB') currentData['IB'] = value;
        if (field == 'IC') currentData['IC'] = value;
        if (field == 'Iavg') currentData['Iavg'] = value;
      } else if (measurement == 'VOLTAGE') {
        if (field == 'Vab') voltageData['Vab'] = value;
        if (field == 'Vbc') voltageData['Vbc'] = value;
        if (field == 'Vca') voltageData['Vca'] = value;
        if (field == 'Vavg') voltageData['Vavg'] = value;
        if (field == 'UAB') voltageData['UAB'] = value;
        if (field == 'UBC') voltageData['UBC'] = value;
        if (field == 'UCA') voltageData['UCA'] = value;
        if (field == 'Uavg') voltageData['Uavg'] = value;
      } else if (measurement == 'POWER') {
        if (field == 'P(kW)') powerData['P(kW)'] = value;
        if (field == 'P(W)') powerData['P(W)'] = value;
        if (field == 'Q(kVAr)') powerData['Q(kVAr)'] = value;
        if (field == 'Q(VAR)') powerData['Q(VAR)'] = value;
        if (field == 'S(kVA)') powerData['S(kVA)'] = value;
        if (field == 'S(VA)') powerData['S(VA)'] = value;
        if (field == 'PF') powerData['PF'] = value;
        if (field == 'Freq') powerData['Freq'] = value;
        if (field == 'PeakDemand') powerData['PeakDemand'] = value;
      } else if (measurement == 'ENERGY') {
        if (field == 'Edel' && !energyData.containsKey('Edel')) {
          energyData['Edel'] = value;
        }
        if (field == 'Erec' && !energyData.containsKey('Erec')) {
          energyData['Erec'] = value;
        }
        if (field == 'Eapp') energyData['Eapp'] = value;
      }
    }

    // Embed timeseries data directly into each data map
    currentData['timeSeries'] = _cachedTimeSeries
        .where((p) => p.measurement.toUpperCase() == 'CURRENT')
        .toList();

    voltageData['timeSeries'] = _cachedTimeSeries
        .where((p) => p.measurement.toUpperCase() == 'VOLTAGE')
        .toList();

    powerData['timeSeries'] = _cachedTimeSeries
        .where((p) => p.measurement.toUpperCase() == 'POWER')
        .toList();

    energyData['timeSeries'] = _cachedTimeSeries
        .where((p) => p.measurement.toUpperCase() == 'ENERGY')
        .toList();

    return SensorData(
      current: currentData.isEmpty ? {'value': 'No Data'} : currentData,
      voltage: voltageData.isEmpty ? {'value': 'No Data'} : voltageData,
      power: powerData.isEmpty ? {'value': 'No Data'} : powerData,
      energy: energyData.isEmpty ? {'value': 'No Data'} : energyData,
    );
  }

  /// Query energy statistics (peak and average)
  Future<Map<String, double>> queryEnergyStats(String deviceId) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/stats/$deviceId'), headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'peak': (data['peak'] ?? 0).toDouble(),
          'average': (data['average'] ?? 0).toDouble(),
        };
      } else {
        throw Exception('Failed to fetch energy stats: ${response.statusCode}');
      }
    } catch (e) {
      _handleError('Error fetching energy stats: $e');
      return {'peak': 0.0, 'average': 0.0};
    }
  }

  void _handleError(String error) {
    // dispose() closes the client on purpose, which aborts whatever was still
    // in flight. Those aborts surface here as "Client is already closed" and
    // are the shutdown working as intended, not a fetch that failed — so they
    // must not be reported. Passing them on buried the real errors in noise
    // and, worse, drove callers to overwrite good readings with zeroes.
    if (_isDisposed) return;
    print(error);
    if (onError != null) {
      onError!(error);
    }
  }

  void _stopPolling() {
    if (_pollingTimer != null) LeakProbe.unregister('InfluxDB.pollTimer');
    _pollingTimer?.cancel();
    _pollingTimer = null;
    if (_timeSeriesTimer != null) LeakProbe.unregister('InfluxDB.seriesTimer');
    _timeSeriesTimer?.cancel();
    _timeSeriesTimer = null;
  }

  void dispose() {
    if (!_isDisposed) LeakProbe.unregister('InfluxDBService');
    _isDisposed = true;
    _stopPolling();
    _client.close();
    _cachedTimeSeries.clear();
  }
}
