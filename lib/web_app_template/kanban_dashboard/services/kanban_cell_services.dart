import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/models/response.dart';

class KanbanCellServices {
  static const String _dataUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static const String _allMachines = 'MSB,CM1,CM2,TD7,TD8,TD9,TD9_SUB,TD10,MOTAN,C2,C7,C8,C9,C10,CA';
  static const List<String> _allMachineIds = [
    'MSB',
    'CM1',
    'CM2',
    'TD7',
    'TD8',
    'TD9',
    'TD9_SUB',
    'TD10',
    'MOTAN',
    'C2',
    'C7',
    'C8',
    'C9',
    'C10',
    'CA',
  ];

  // ── Entry point ──────────────────────────────────────────────────────────────
  static Future<KanbanCellResponse> fetch(
    String widgetType,
    Map<String, dynamic> config,
  ) async {
    switch (widgetType) {
      case 'EQUIPMENT_MD_RANKING':
        return _fetchMdRanking(config);
      case 'HOURLY_CHART':
        return _fetchHourly(config);
      case 'DAILY_CHART':
        return _fetchDaily(config);
      case 'MONTHLY_CHART':
        return _fetchMonthly(config);
      case 'YEAR_OVER_YEAR_CHART':
        return _fetchYearOverYear(config);
      case 'LAST_24H_CHART':
        return _fetchLast24h(config);
      case 'POWER_LOAD_TREND':
        return _fetchPowerLoadTrend(config);
      case 'DAILY_MAX_DEMAND':
        return _fetchDailyMaxDemand(config);
      case 'POWER_LOAD_DISTRIBUTION_TODAY':
        return _fetchPowerLoadDistribution(config);
      case 'YEAR_ON_YEAR_ANALYSIS':
        return _fetchYearOnYearAnalysis(config);
      case 'EQUIPMENT_LOAD_CORRELATION':
        return _fetchEquipmentLoadCorrelation(config);
      default:
        return KanbanCellResponse();
    }
  }

  // ── Shared helpers ───────────────────────────────────────────────────────────
  static List<Map<String, dynamic>> _parseList(dynamic jsonData) {
    List<dynamic> raw;
    if (jsonData is List) {
      raw = jsonData;
    } else if (jsonData is Map && jsonData.containsKey('data')) {
      raw = jsonData['data'] as List<dynamic>;
    } else {
      return [];
    }
    return raw
        .map<Map<String, dynamic>>((item) => {
              'label': item['label'].toString(),
              'value': (item['value'] is num ? item['value'] as num : 0).toDouble(),
            })
        .toList();
  }

  static Future<List<Map<String, dynamic>>> _getList(Uri uri) async {
    final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return _parseList(jsonDecode(res.body));
    return [];
  }

  /// InfluxDB shape: {data: {current: [...], previous: [...]}}
  static ({
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> previous,
  }) _parseInfluxHourly(Map<String, dynamic> jsonData) {
    List<dynamic> currentList = [];
    List<dynamic> previousList = [];

    if (jsonData.containsKey('data')) {
      final dataObj = jsonData['data'];
      if (dataObj is Map) {
        currentList = dataObj['current'] ?? [];
        previousList = dataObj['previous'] ?? [];
      }
    }

    List<Map<String, dynamic>> parse(List<dynamic> list) => list
        .map<Map<String, dynamic>>((item) => {
              'label': item['label']?.toString() ?? '',
              'value': item['value'] is num ? (item['value'] as num).toDouble() : 0.0,
              'time': item['time']?.toString() ?? item['label']?.toString() ?? '',
            })
        .toList();

    return (current: parse(currentList), previous: parse(previousList));
  }

  // ── EQUIPMENT_MD_RANKING ─────────────────────────────────────────────────────
  static Future<MdRankingResponse> _fetchMdRanking(
    Map<String, dynamic> config,
  ) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final eventDate = (config['eventDate'] as String?)?.isNotEmpty == true ? config['eventDate'] as String : fmt.format(DateTime.now());
    final eventStart = config['eventStart'] as String? ?? '';
    final eventEnd = config['eventEnd'] as String? ?? '';

    final uri = Uri.parse(
      '$_dataUrl/energyDetails/equipment-md-ranking'
      '?device_id=$_allMachines'
      '&event_date=$eventDate'
      '&event_start=$eventStart'
      '&event_end=$eventEnd',
    );

    final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final rawData = body['data'] as List<dynamic>? ?? [];
      final parsed = rawData
          .map((item) => <String, dynamic>{
                'device_id': item['device_id']?.toString() ?? 'Unknown',
                'peak_demand_kW': (item['peak_demand_kW'] ?? 0.0 as num).toDouble(),
                'percentage': (item['percentage'] ?? 0.0 as num).toDouble(),
              })
          .toList();
      parsed.sort((a, b) => (b['peak_demand_kW'] as double).compareTo(a['peak_demand_kW'] as double));
      return MdRankingResponse(data: parsed);
    }

    String msg = 'Failed to load data: ${res.statusCode}';
    try {
      msg = (jsonDecode(res.body) as Map)['error']?.toString() ?? msg;
    } catch (_) {}
    throw Exception(msg);
  }

  // ── HOURLY_CHART ─────────────────────────────────────────────────────────────
  static Future<HourlyChartResponse> _fetchHourly(
    Map<String, dynamic> config,
  ) async {
    final topic = config['topic'] as String? ?? 'MSB';
    if (topic.isEmpty) {
      return HourlyChartResponse(data: const [], previousData: const [], selectedDate: DateTime.now());
    }

    final DateTime date = config['selectedDate'] is DateTime
        ? config['selectedDate'] as DateTime
        : DateTime.tryParse(config['selectedDate'] as String? ?? '') ?? DateTime.now();

    final fmt = DateFormat('yyyy-MM-dd');
    final today = fmt.format(date);
    final yesterday = fmt.format(date.subtract(const Duration(days: 1)));

    final results = await Future.wait([
      _getList(Uri.parse('$_dataUrl/energyDetails/data/$topic/hourly?date=$today')),
      _getList(Uri.parse('$_dataUrl/energyDetails/data/$topic/hourly?date=$yesterday')),
    ]);

    return HourlyChartResponse(data: results[0], previousData: results[1], selectedDate: date);
  }

  // ── DAILY_CHART ──────────────────────────────────────────────────────────────
  static Future<DailyChartResponse> _fetchDaily(Map<String, dynamic> config) async {
    final topic = config['topic'] as String? ?? 'MSB';
    if (topic.isEmpty) return const DailyChartResponse(data: []);
    final data = await _getList(Uri.parse('$_dataUrl/energyDetails/data/$topic/daily'));
    return DailyChartResponse(data: data);
  }

  // ── MONTHLY_CHART ────────────────────────────────────────────────────────────
  static Future<MonthlyChartResponse> _fetchMonthly(Map<String, dynamic> config) async {
    final topic = config['topic'] as String? ?? 'MSB';
    if (topic.isEmpty) return const MonthlyChartResponse(data: []);
    final data = await _getList(Uri.parse('$_dataUrl/energyDetails/data/$topic/monthly'));
    return MonthlyChartResponse(data: data);
  }

  // ── YEAR_OVER_YEAR_CHART ─────────────────────────────────────────────────────
  static Future<YearOverYearChartResponse> _fetchYearOverYear(Map<String, dynamic> config) async {
    final topic = config['topic'] as String? ?? 'MSB';
    if (topic.isEmpty) return const YearOverYearChartResponse(data: [], previousData: []);

    final currentYear = DateTime.now().year;
    final results = await Future.wait([
      _getList(Uri.parse('$_dataUrl/energyDetails/data/$topic/yearly?year=$currentYear')),
      _getList(Uri.parse('$_dataUrl/energyDetails/data/$topic/yearly?year=${currentYear - 1}')),
    ]);
    return YearOverYearChartResponse(data: results[0], previousData: results[1]);
  }

  // ── LAST_24H_CHART ───────────────────────────────────────────────────────────
  static Future<Last24hChartResponse> _fetchLast24h(Map<String, dynamic> config) async {
    final topic = config['topic'] as String? ?? 'MSB';
    if (topic.isEmpty) return const Last24hChartResponse(data: [], previousData: []);

    final duration = config['duration'] as String? ?? '1h';
    final DateTime date = config['selectedDate'] is DateTime
        ? config['selectedDate'] as DateTime
        : DateTime.tryParse(config['selectedDate'] as String? ?? '') ?? DateTime.now();

    final dateString = DateFormat('yyyy-MM-dd').format(date);
    final url = '$_dataUrl/energyDetailsInfluxDb/data/$topic/hourly'
        '?date=$dateString&duration=$duration';

    print('ðŸ• LAST_24H_CHART fetching: $url');

    try {
      final res = await http.get(Uri.parse(url), headers: AppConfig.headers).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final parsed = _parseInfluxHourly(jsonDecode(res.body) as Map<String, dynamic>);
        print('✅ LAST_24H_CHART — current: ${parsed.current.length} pts, previous: ${parsed.previous.length} pts');
        return Last24hChartResponse(data: parsed.current, previousData: parsed.previous);
      }
      print('âŒ LAST_24H_CHART error: ${res.statusCode}');
    } catch (e) {
      print('âŒ LAST_24H_CHART exception: $e');
    }
    return const Last24hChartResponse(data: [], previousData: []);
  }

  // ── POWER_LOAD_TREND ─────────────────────────────────────────────────────────
  /// Mirrors MaxDemandMonitoring._fetchPowerLoadData()
  static Future<PowerLoadTrend24hResponse> _fetchPowerLoadTrend(
    Map<String, dynamic> config,
  ) async {
    final topic = config['topic'] as String? ?? 'MSB';

    try {
      final res = await http
          .get(
            Uri.parse('$_dataUrl/energyDetails/power-load-24h/$topic'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;

        // ✅ Mirrors MaxDemandMonitoring: extract statistics first
        double maxPowerKw = 0.0;
        double minPowerKw = 0.0;
        if (data['statistics'] != null) {
          maxPowerKw = (data['statistics']['max_demand_kW'] ?? 0.0).toDouble();
          minPowerKw = (data['statistics']['min_demand_kW'] ?? 0.0).toDouble();
        }

        // ✅ Mirrors MaxDemandMonitoring: map time_label + max_demand_kW
        final powerLoadData = data['data'] != null
            ? (data['data'] as List<dynamic>)
                .map<Map<String, dynamic>>((item) => {
                      'time_label': item['time_label']?.toString() ?? '',
                      'max_demand_kW': (item['max_demand_kW'] ?? 0.0).toDouble(),
                    })
                .toList()
            : <Map<String, dynamic>>[];

        print('✅ POWER_LOAD_TREND — ${powerLoadData.length} pts, max: $maxPowerKw kW');

        return PowerLoadTrend24hResponse(
          data: powerLoadData,
          powerLoadData: powerLoadData,
          maxPowerKw: maxPowerKw,
          minPowerKw: minPowerKw,
        );
      }
      print('âŒ POWER_LOAD_TREND error: ${res.statusCode}');
    } catch (e) {
      print('âŒ POWER_LOAD_TREND exception: $e');
    }
    return const PowerLoadTrend24hResponse(data: [], powerLoadData: []);
  }

  // ── DAILY_MAX_DEMAND ─────────────────────────────────────────────────────────
  /// Mirrors MaxDemandMonitoring._fetchMaxDemandData()
  static Future<DailyMaxDemandResponse> _fetchDailyMaxDemand(
    Map<String, dynamic> config,
  ) async {
    final topic = config['topic'] as String? ?? 'MSB';

    try {
      final res = await http
          .get(
            Uri.parse('$_dataUrl/energyDetails/max-demand-chart?device_id=$topic'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        // ✅ Mirrors MaxDemandMonitoring: response is a plain List
        final List<dynamic> raw = jsonDecode(res.body);
        final data = raw
            .map<Map<String, dynamic>>((item) => {
                  'label': item['label']?.toString() ?? '',
                  'value': (item['value'] ?? 0.0).toDouble(),
                  'date': item['date']?.toString() ?? '',
                })
            .toList();

        print('✅ DAILY_MAX_DEMAND — ${data.length} pts');
        return DailyMaxDemandResponse(data: data);
      }
      print('âŒ DAILY_MAX_DEMAND error: ${res.statusCode}');
    } catch (e) {
      print('âŒ DAILY_MAX_DEMAND exception: $e');
    }
    return const DailyMaxDemandResponse(data: []);
  }

  // ── POWER_LOAD_DISTRIBUTION ──────────────────────────────────────────────────
  /// Mirrors MaxDemandMonitoring._fetchAveragePowerLoadDistribution()
  static Future<PowerLoadDistributionResponse> _fetchPowerLoadDistribution(
    Map<String, dynamic> config,
  ) async {
    final topic = config['topic'] as String? ?? 'MSB';

    try {
      final res = await http
          .get(
            Uri.parse('$_dataUrl/energyDetails/average-power-load/$topic'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final responseData = jsonDecode(res.body) as Map<String, dynamic>;

        // ✅ Mirrors MaxDemandMonitoring: map all 4 fields
        final data = (responseData['data'] as List<dynamic>)
            .map<Map<String, dynamic>>((item) => {
                  'time_period': item['time_period']?.toString() ?? '',
                  'average_power_load_kW': (item['average_power_load_kW'] ?? 0.0).toDouble(),
                  'total_energy_kWh': (item['total_energy_kWh'] ?? 0.0).toDouble(),
                  'hours_count': (item['hours_count'] ?? 0) as int,
                })
            .toList();

        print('✅ POWER_LOAD_DISTRIBUTION — ${data.length} entries');
        return PowerLoadDistributionResponse(data: data);
      }
      print('âŒ POWER_LOAD_DISTRIBUTION error: ${res.statusCode}');
    } catch (e) {
      print('âŒ POWER_LOAD_DISTRIBUTION exception: $e');
    }
    return const PowerLoadDistributionResponse(data: []);
  }

  // ── YEAR_ON_YEAR_ANALYSIS ────────────────────────────────────────────────────
  /// Mirrors MaxDemandMonitoring._fetchYearOnYearAnalysis()
  static Future<YearOnYearAnalysisResponse> _fetchYearOnYearAnalysis(
    Map<String, dynamic> config,
  ) async {
    final topic = config['topic'] as String? ?? 'MSB';

    try {
      final res = await http
          .get(
            Uri.parse('$_dataUrl/energyDetails/year-on-year-analysis?device_id=$topic'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final responseData = jsonDecode(res.body) as Map<String, dynamic>;

        // ✅ Mirrors MaxDemandMonitoring: map all 5 fields
        final data = (responseData['data'] as List<dynamic>)
            .map<Map<String, dynamic>>((item) => {
                  'month': (item['month'] as int?) ?? 0,
                  'month_label': (item['month_label'] as String?) ?? '',
                  'previous_period_max_demand_kW': ((item['previous_period_max_demand_kW'] ?? 0) as num).toDouble(),
                  'current_period_max_demand_kW': ((item['current_period_max_demand_kW'] ?? 0) as num).toDouble(),
                  'device_id': item['device_id']?.toString() ?? '',
                })
            .toList();

        // ✅ Mirrors MaxDemandMonitoring: parse comparison block
        List<Map<String, dynamic>> comparisonData = [];
        if (responseData['comparison'] != null) {
          final c = responseData['comparison'] as Map<String, dynamic>;
          comparisonData = [
            {
              'previous_period': c['previous_period'] ?? 'Previous Period',
              'current_period': c['current_period'] ?? 'Current Period',
              'description': c['description'] ?? '',
            }
          ];
        }

        print('✅ YEAR_ON_YEAR_ANALYSIS — ${data.length} months');
        return YearOnYearAnalysisResponse(data: data, comparisonYearData: comparisonData);
      }
      print('âŒ YEAR_ON_YEAR_ANALYSIS error: ${res.statusCode}');
    } catch (e) {
      print('âŒ YEAR_ON_YEAR_ANALYSIS exception: $e');
    }
    return const YearOnYearAnalysisResponse(data: [], comparisonYearData: []);
  }

  // ── EQUIPMENT_LOAD_CORRELATION ───────────────────────────────────────────────
  /// Mirrors MaxDemandMonitoring._fetchCorrelationData()
  static Future<EquipmentLoadCorrelationResponse> _fetchEquipmentLoadCorrelation(
    Map<String, dynamic> config,
  ) async {
    final rawDate = (config['eventDate'] as String?)?.trim() ?? '';

    final now = DateTime.now();

    final eventDate = rawDate.isNotEmpty ? rawDate : '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (eventDate.isEmpty) {
      return const EquipmentLoadCorrelationResponse(
        data: [],
        seriesData: {},
        deviceIds: [],
      );
    }

    final eventStart = config['eventStart'] as String? ?? '';
    final eventEnd = config['eventEnd'] as String? ?? '';
    final interval = config['interval'] as String? ?? '30m';

    try {
      final uri = Uri.parse(
        '$_dataUrl/energyDetailsInfluxDb/equipment-load-correlation'
        '?device_id=$_allMachines'
        '&event_date=$eventDate'
        '&event_start=$eventStart'
        '&event_end=$eventEnd'
        '&interval=$interval',
      );

      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final responseData = jsonDecode(res.body) as Map<String, dynamic>;

        // ✅ Mirrors MaxDemandMonitoring: build seriesMap keyed by device_id
        final Map<String, List<Map<String, dynamic>>> seriesMap = {
          for (final id in _allMachineIds) id: [],
        };

        final rawList = responseData['data'] as List<dynamic>? ?? [];
        for (final item in rawList) {
          final deviceId = item['device_id']?.toString() ?? 'Unknown';
          final time = item['time_label']?.toString() ?? '';
          final value = (item['power_kW'] ?? 0.0).toDouble();
          seriesMap.putIfAbsent(deviceId, () => []);
          seriesMap[deviceId]!.add({'time': time, 'value': value});
        }

        // ✅ Mirrors MaxDemandMonitoring: merge known + extra device ids
        final deviceIds = _allMachineIds.toList()..addAll(seriesMap.keys.where((k) => !_allMachineIds.contains(k)));

        final systemPeak = (responseData['system_peak_kW'] ?? 0.0).toDouble();

        print('✅ EQUIPMENT_LOAD_CORRELATION — ${rawList.length} pts, peak: $systemPeak kW');

        return EquipmentLoadCorrelationResponse(
          data: rawList
              .map<Map<String, dynamic>>((item) => {
                    'device_id': item['device_id']?.toString() ?? '',
                    'time_label': item['time_label']?.toString() ?? '',
                    'power_kW': (item['power_kW'] ?? 0.0).toDouble(),
                  })
              .toList(),
          seriesData: seriesMap,
          deviceIds: deviceIds,
          systemPeak: systemPeak,
          selectedEventDate: eventDate,
          selectedEventStart: eventStart,
          selectedEventEnd: eventEnd,
        );
      }
      print('âŒ EQUIPMENT_LOAD_CORRELATION error: ${res.statusCode}');
    } catch (e) {
      print('âŒ EQUIPMENT_LOAD_CORRELATION exception: $e');
    }
    return const EquipmentLoadCorrelationResponse(data: [], seriesData: {}, deviceIds: []);
  }
}
