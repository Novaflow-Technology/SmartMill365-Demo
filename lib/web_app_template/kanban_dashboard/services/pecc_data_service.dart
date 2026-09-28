import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/models/pecc_live_data.dart';

class _PeccMapping {
  final String key;
  final String device;
  final String field;
  final String label;

  /// Card definitions saved against a map pin: metricKey, colorKey, label.
  /// Kept as raw maps because this layer only forwards them to the resolver.
  final List<Map<String, dynamic>> metricSpecs;

  /// Position on the aerial photo, 0-100 as typed in settings. Null when the
  /// pin has never been moved.
  final double? xPct;
  final double? yPct;

  /// The solar device for this site, empty when it has none.
  final String solarDevice;

  const _PeccMapping({
    required this.key,
    required this.device,
    required this.field,
    required this.label,
    this.metricSpecs = const [],
    this.xPct,
    this.yPct,
    this.solarDevice = '',
  });

  bool get isMapped => device.isNotEmpty && field.isNotEmpty;
}

class _DeviceEnergy {
  double dailyKwh = 0;
  double monthlyKwh = 0;
  double dailyCarbonKg = 0;
}

/// Flat rate used only when the billing endpoints return nothing.
///
/// A real bill has tiered energy, maximum demand and ICPT in it, so this is an
/// estimate, not a substitute for one. It exists because a dash tells an
/// operator nothing, and the group dashboard has used this same rate for the
/// same reason since before the per-plant views existed — one rate in one
/// place rather than two that can drift.
const double _fallbackTariffRmPerKwh = 0.365;


class _TnbBill {
  double totalBill = 0;
  double totalUsageKwh = 0;

  /// The maximum-demand component of the bill. The billing endpoint breaks the
  /// total down — mdAmount, peakAmount, offPeakAmount, icptAmount,
  /// pfPenaltyAmount — so this is read rather than worked out again here.
  double mdChargeRm = 0;

  double estimateDailyCost(double dailyKwh) =>
      totalUsageKwh > 0 ? dailyKwh * (totalBill / totalUsageKwh) : 0;
}

typedef _Hourly24hSeries = ({
  List<double> powerKw,
  List<double> mdKw,
  List<String> labels
});
typedef _LabeledSeries = ({List<double> values, List<String> labels});

/// Dedupes HTTP calls within a single PECC resolve (same device → one request).
class _PeccRequestCache {
  static const _emptyHourly =
      (powerKw: <double>[], mdKw: <double>[], labels: <String>[]);
  static const _emptyLabeled = (values: <double>[], labels: <String>[]);

  final Map<String, Future<_Hourly24hSeries>> _hourly24h = {};
  final Map<String, Future<_LabeledSeries>> _dailySeries = {};
  final Map<String, Future<_LabeledSeries>> _dailyMaxDemand = {};
  final Map<String, Future<_LabeledSeries>> _hourlySolar = {};
  final Map<String, Future<Map<String, dynamic>>> _tnbSimulator = {};
  final Map<String, Future<double>> _contractKw = {};
  final Map<String, Future<List<({int hour, double kwh})>>> _hourlyKwhToday =
      {};
  final Map<String, Future<double>> _powerFactor = {};

  Future<_Hourly24hSeries> hourly24h(String deviceId) {
    if (deviceId.isEmpty) return Future.value(_emptyHourly);
    return _hourly24h.putIfAbsent(
        deviceId, () => PeccDataService._fetchHourly24hSeriesCached(deviceId));
  }

  Future<_LabeledSeries> dailySeries(String deviceId) {
    if (deviceId.isEmpty) return Future.value(_emptyLabeled);
    return _dailySeries.putIfAbsent(
        deviceId, () => PeccDataService._fetchDailySeriesKwh(deviceId));
  }

  Future<_LabeledSeries> dailyMaxDemand(String deviceId) {
    if (deviceId.isEmpty) return Future.value(_emptyLabeled);
    return _dailyMaxDemand.putIfAbsent(deviceId,
        () => PeccDataService._fetchDailyMaxDemandThisMonthKw(deviceId));
  }

  Future<_LabeledSeries> hourlySolar(String deviceId) {
    if (deviceId.isEmpty) return Future.value(_emptyLabeled);
    return _hourlySolar.putIfAbsent(
        deviceId, () => PeccDataService._fetchHourlySolarSeries(deviceId));
  }

  Future<Map<String, dynamic>> tnbSimulator(String deviceId) {
    if (deviceId.isEmpty) return Future.value({});
    return _tnbSimulator.putIfAbsent(
        deviceId, () => PeccDataService._fetchTnbSimulator(deviceId));
  }

  Future<double> contractKw(String userId, String deviceId, String categoryId) {
    if (deviceId.isEmpty) return Future.value(2100.0);
    final key = '$userId|$deviceId|$categoryId';
    return _contractKw.putIfAbsent(key, () async {
      // Same resolution order as Max Demand Monitoring: TNB Meter Setting
      // contractMdKw first, then billing config, then bill-simulator fallback.
      final fromMeter = await PeccDataService._contractKwFromTnbMeter(deviceId);
      if (fromMeter > 0) return fromMeter;
      try {
        if (userId.isNotEmpty) {
          // Billing config is shared across every user of this client, not
          // per-login — see AppConfig.sharedConfigOwnerId.
          final billingUri = categoryId.isNotEmpty
              ? '${PeccDataService._dataBase}/masterBillingConfig/${AppConfig.sharedConfigOwnerId}/$categoryId'
              : '${PeccDataService._dataBase}/masterBillingConfig/${AppConfig.sharedConfigOwnerId}/active';
          final res = await http
              .get(Uri.parse(billingUri), headers: AppConfig.headers)
              .timeout(const Duration(seconds: 8));
          if (res.statusCode == 200) {
            final root = jsonDecode(res.body) as Map<String, dynamic>;
            final cfg = root['config'] as Map<String, dynamic>? ?? root;
            final md = PeccDataService._toDouble(
              cfg['contractMdKw'] ??
                  cfg['contract_md_kW'] ??
                  cfg['mdContractKw'],
            );
            if (md > 0) return md;
          }
        }
        final sim = await tnbSimulator(deviceId);
        final fromSim = PeccDataService._toDouble(
            sim['contract_md_kW'] ?? sim['contractMdKw']);
        if (fromSim > 0) return fromSim;
      } catch (_) {}
      return 2100.0;
    });
  }

  Future<List<({int hour, double kwh})>> hourlyKwhToday(String deviceId) {
    if (deviceId.isEmpty) return Future.value([]);
    return _hourlyKwhToday.putIfAbsent(
        deviceId, () => PeccDataService._fetchHourlyKwhToday(deviceId));
  }

  Future<double> powerFactor(String deviceId) {
    if (deviceId.isEmpty) return Future.value(0.0);
    return _powerFactor.putIfAbsent(
        deviceId, () => PeccDataService._fetchLatestPowerFactorMysql(deviceId));
  }

  Future<void> prefetchAll(Iterable<Future<void>> tasks,
      {int maxConcurrent = 5}) async {
    final list = tasks.toList();
    for (var i = 0; i < list.length; i += maxConcurrent) {
      await Future.wait(list.skip(i).take(maxConcurrent));
    }
  }
}

/// Resolves PECC mappings → kWh (energyDetails) + RM (TNB Bill Simulator total).
class PeccDataService {
  static const _dataBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

  static String? _bootstrapCacheKey;
  static DateTime? _bootstrapCacheAt;
  static Map<String, _DeviceEnergy> _bootstrapEnergy = {};
  static Map<String, _TnbBill> _bootstrapBills = {};

  static final _energyCache = <String, _DeviceEnergy>{};
  static final _energyCacheAt = <String, DateTime>{};
  static final _billCache = <String, _TnbBill>{};
  static final _billCacheAt = <String, DateTime>{};
  static final _masterBillingCache = <String, Map<String, dynamic>>{};
  static final _masterBillingCacheAt = <String, DateTime>{};
  static bool _resolveInFlight = false;
  static Future<PeccLiveData>? _resolveInFlightFuture;
  static final Map<String, DateTime> _tnbMeterDataAt = {};
  static final Map<String, List<Map<String, dynamic>>> _tnbMeterData = {};
  static final Map<String, Future<List<Map<String, dynamic>>>>
      _tnbMeterDataRequests = {};

  static ({Map<String, _DeviceEnergy> energy, Map<String, _TnbBill> bills})?
      _readBootstrapCache(String key) {
    final at = _bootstrapCacheAt;
    if (_bootstrapCacheKey != key || at == null) return null;
    if (DateTime.now().difference(at) > const Duration(seconds: 180))
      return null;
    return (
      energy: Map<String, _DeviceEnergy>.from(_bootstrapEnergy),
      bills: Map<String, _TnbBill>.from(_bootstrapBills)
    );
  }

  static void _saveBootstrapCache(String key, Map<String, _DeviceEnergy> energy,
      Map<String, _TnbBill> bills) {
    _bootstrapCacheKey = key;
    _bootstrapCacheAt = DateTime.now();
    _bootstrapEnergy = Map<String, _DeviceEnergy>.from(energy);
    _bootstrapBills = Map<String, _TnbBill>.from(bills);
  }

  static void _cleanStaleCacheEntries() {
    final now = DateTime.now();
    _purgeCacheByTimestamp(
        _energyCache, _energyCacheAt, now, const Duration(minutes: 5));
    _purgeCacheByTimestamp(
        _billCache, _billCacheAt, now, const Duration(minutes: 5));
    _purgeCacheByTimestamp(_masterBillingCache, _masterBillingCacheAt, now,
        const Duration(minutes: 5));
    _purgeCacheByTimestamp(
        _tnbMeterData, _tnbMeterDataAt, now, const Duration(minutes: 5));
    _purgeHourlySeriesCache(now);

    if (_bootstrapCacheAt != null &&
        now.difference(_bootstrapCacheAt!).inMinutes >= 5) {
      _bootstrapCacheKey = null;
      _bootstrapCacheAt = null;
      _bootstrapEnergy.clear();
      _bootstrapBills.clear();
    }
  }

  static void _purgeCacheByTimestamp<K, V>(
    Map<K, V> cache,
    Map<K, DateTime> timestamps,
    DateTime now,
    Duration ttl, {
    int maxEntries = 50,
  }) {
    final expiredKeys = timestamps.entries
        .where((entry) => now.difference(entry.value) >= ttl)
        .map((entry) => entry.key)
        .toList();
    for (final key in expiredKeys) {
      cache.remove(key);
      timestamps.remove(key);
    }

    if (cache.length <= maxEntries) return;
    final keysByAge = timestamps.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final removeCount = cache.length - maxEntries;
    for (var i = 0; i < removeCount && i < keysByAge.length; i++) {
      final key = keysByAge[i].key;
      cache.remove(key);
      timestamps.remove(key);
    }
  }

  static void _purgeHourlySeriesCache(DateTime now, [int maxEntries = 50]) {
    final expiredKeys = _hourlySeriesCache.entries
        .where((entry) =>
            now.difference(entry.value.$1) >= const Duration(seconds: 45))
        .map((entry) => entry.key)
        .toList();
    for (final key in expiredKeys) {
      _hourlySeriesCache.remove(key);
    }
    if (_hourlySeriesCache.length <= maxEntries) return;
    final keysByAge = _hourlySeriesCache.entries.toList()
      ..sort((a, b) => a.value.$1.compareTo(b.value.$1));
    final removeCount = _hourlySeriesCache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      _hourlySeriesCache.remove(keysByAge[i].key);
    }
  }

  /// Group map pin index for Lot 237 (6th pin in original 8-pin DB layout).
  static const int _lot237PinIndex = 6;

  static Map<String, _PeccMapping> _parseMappings(
      Map<String, dynamic>? config) {
    final out = <String, _PeccMapping>{};
    if (config == null) return out;
    final sections = config['sections'];
    if (sections is List) {
      for (final sec in sections) {
        if (sec is! Map) continue;
        final widgets = sec['widgets'];
        if (widgets is List) {
          for (final w in widgets) {
            if (w is! Map) continue;
            final key = w['key']?.toString() ?? '';
            if (key.isEmpty) continue;
            out[key] = _PeccMapping(
              key: key,
              device: w['selectedDevice']?.toString() ?? '',
              field: w['selectedField']?.toString() ?? '',
              label: w['label']?.toString() ?? '',
            );
          }
        }
      }
    }
    final pins = config['pins'];
    if (pins is List) {
      for (final p in pins) {
        if (p is! Map) continue;
        final key = p['key']?.toString() ?? '';
        if (key.isEmpty) continue;
        final existing = out[key];
        final deviceVal = p['selectedSiteId']?.toString() ?? '';
        final fieldVal = p['selectedMetric']?.toString() ?? '';
        final labelVal = p['displayName']?.toString() ?? '';
        out[key] = _PeccMapping(
          key: key,
          device: deviceVal.isNotEmpty ? deviceVal : (existing?.device ?? ''),
          field: fieldVal.isNotEmpty ? fieldVal : (existing?.field ?? ''),
          label: labelVal.isNotEmpty ? labelVal : (existing?.label ?? ''),
          metricSpecs: ((p['metrics'] as List<dynamic>?) ?? const [])
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>())
              .where((m) => (m['metricKey']?.toString() ?? '').isNotEmpty)
              .toList(),
          xPct: double.tryParse(p['xPct']?.toString() ?? ''),
          yPct: double.tryParse(p['yPct']?.toString() ?? ''),
          solarDevice: p['solarDevice']?.toString() ?? '',
        );
      }
    }
    return out;
  }

  static _PeccMapping? _m(Map<String, _PeccMapping> map, String key) {
    final direct = map[key];
    if (direct != null) return direct;
    if (key.startsWith('cost_drivers[')) {
      final alt = key.replaceFirst('cost_drivers[', 'pin[');
      return map[alt];
    }
    if (key.startsWith('pin[')) {
      final alt = key.replaceFirst('pin[', 'cost_drivers[');
      return map[alt];
    }
    return null;
  }

  /// Lot 237 panel -> the widget keys it feeds.
  /// Panel -> the widget keys a Meter Group may fill.
  ///
  /// Only keys where the group's SUM is the right answer belong here. A panel
  /// gets one synthetic device for all of its keys, so keys that mean different
  /// things must not be listed together:
  ///   blockA/B/C.total  - each block needs its own group, not the plant sum,
  ///                       or all three cards would show the same number
  ///   hero[0] / hero[1] - Total Energy and Solar are different metrics; one
  ///                       shared device would make solar equal total
  /// Those panels stay on their per-widget mappings. flowSummary and energyMix
  /// are safe because the resolver derives solar/grid/total from the device
  /// itself rather than reading each key straight through.
  static const _lot237PanelKeys = <String, List<String>>{
    'flowMap': ['flow.plantTotal'],
    'flowSummary': ['flowSummary[0]', 'flowSummary[1]', 'flowSummary[2]', 'flowSummary[3]'],
    'energyMix': ['donut.solar', 'donut.grid', 'donut.center'],
    'trend': ['trend.total', 'trend.grid', 'trend.solar'],
    'blockChart': ['chart.blockBars', 'chart.timestamp'],
  };


  /// Makes the Dashboard Panels setup drive real numbers.
  ///
  /// A panel points at a Meter Group; the resolver only understands one device
  /// per widget key. So each panel's members are fetched, summed into a single
  /// synthetic device (`grp:<panel>`) placed in [energyCache], and the panel's
  /// widget keys are pointed at it.
  ///
  /// An explicit per-widget mapping always wins — a group only fills keys that
  /// are still unmapped. That keeps every existing Lot 237 mapping working
  /// exactly as before and limits groups to filling the gaps.
  static Future<void> _applyGroupPanels(
    Map<String, dynamic> ecConfig,
    Map<String, _PeccMapping> mappings,
    Map<String, _DeviceEnergy> energyCache,
  ) async {
    final branding = ecConfig['branding'] is Map
        ? Map<String, dynamic>.from(ecConfig['branding'] as Map)
        : const <String, dynamic>{};
    final nested = branding['factoryOverview'] is Map
        ? Map<String, dynamic>.from(branding['factoryOverview'] as Map)
        : const <String, dynamic>{};

    final rawGroups = (ecConfig['groups'] as List<dynamic>?)?.isNotEmpty == true
        ? ecConfig['groups'] as List<dynamic>
        : (nested['groups'] as List<dynamic>? ?? const []);
    final rawCards = ecConfig['cards'] is Map && (ecConfig['cards'] as Map).isNotEmpty
        ? Map<String, dynamic>.from(ecConfig['cards'] as Map)
        : (nested['cards'] is Map
            ? Map<String, dynamic>.from(nested['cards'] as Map)
            : const <String, dynamic>{});
    if (rawGroups.isEmpty || rawCards.isEmpty) return;

    final members = <String, List<String>>{};
    for (final g in rawGroups.whereType<Map>()) {
      final id = g['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      members[id] = (g['members'] as List<dynamic>? ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    for (final entry in _lot237PanelKeys.entries) {
      final keys = entry.value.where((k) {
        final m = mappings[k];
        return m == null || !m.isMapped;
      }).toList();
      if (keys.isEmpty) continue; // every key already mapped explicitly

      final card = rawCards[entry.key];
      if (card is! Map) continue;
      final ids = <String>{...(members[card['groupId']?.toString() ?? ''] ?? const [])};
      for (final i in (card['include'] as List<dynamic>? ?? const [])) {
        ids.add(i.toString());
      }
      for (final e in (card['exclude'] as List<dynamic>? ?? const [])) {
        ids.remove(e.toString());
      }
      ids.removeWhere((e) => e.isEmpty);
      if (ids.isEmpty) continue;

      // Fetch any member not already cached, two at a time like the rest of
      // this service, then sum.
      final missing = ids.where((d) => !energyCache.containsKey(d)).toList();
      for (var i = 0; i < missing.length; i += 2) {
        await Future.wait(missing.skip(i).take(2).map((d) async {
          energyCache[d] = await _fetchEnergy(d);
        }));
      }
      final sum = _DeviceEnergy();
      for (final d in ids) {
        final e = energyCache[d];
        if (e == null) continue;
        sum.dailyKwh += e.dailyKwh;
        sum.monthlyKwh += e.monthlyKwh;
        sum.dailyCarbonKg += e.dailyCarbonKg;
      }
      final synthetic = 'grp:${entry.key}';
      energyCache[synthetic] = sum;
      for (final k in keys) {
        mappings[k] = _PeccMapping(
          key: k,
          device: synthetic,
          field: 'Total Energy (kWh)',
          label: mappings[k]?.label ?? k,
        );
      }
    }
  }

  static Future<PeccLiveData> resolve({
    required Map<String, dynamic> ecConfig,
    required String userId,
    bool includeCharts = true,
    void Function(PeccLiveData data)? onProgress,
  }) async {
    if (_resolveInFlight) {
      return await _resolveInFlightFuture!;
    }

    _cleanStaleCacheEntries();
    _resolveInFlight = true;
    final completer = Completer<PeccLiveData>();
    _resolveInFlightFuture = completer.future;
    try {
      final mappings = _parseMappings(ecConfig);
      if (mappings.values.every((m) => !m.isMapped)) {
        final result = PeccLiveData.empty;
        completer.complete(result);
        return result;
      }

      final plantId = ecConfig['plantId']?.toString().trim() ?? '';
      final isGroup = plantId.isEmpty;
      final plantLower = plantId.toLowerCase();
      final isLot237 = plantLower == 'lot 237';
      // Same routing rule kanban_dashboard_widget.dart uses to choose
      // LotCommandCenterWidget: every plant except the group view, Lot 48,
      // and a Lot 237 block reads the hero[0]/flow.*/sidebar[]/chart.* keys
      // below — that vocabulary is the standard dashboard shape for a new
      // plant now, not something only Lot 237 gets.
      const flexiExcluded = {
        'lot 48',
        'lot 237 block a', 'lot237blocka', 'block a',
        'lot 237 block b', 'lot237blockb', 'block b',
        'lot 237 block c', 'lot237blockc', 'block c',
      };
      final isFlexiPlant =
          plantLower.isNotEmpty && !flexiExcluded.contains(plantLower);

      late final Map<String, String> deviceCategories;
      late final String lot237BillingDevice;
      if (isLot237) {
        deviceCategories = {};
        final heroDev =
            (_m(mappings, 'hero[0]') ?? _m(mappings, 'glance[0]'))?.device ??
                '';
        final plantMeter = await _lotBillingDevice(userId, plantId);
        lot237BillingDevice = plantMeter.isNotEmpty
            ? plantMeter
            : (heroDev.isNotEmpty ? heroDev : 'VDPM002');
      } else {
        final setup = await Future.wait([
          _loadTnbMeterCategories(userId),
          _lotBillingDevice(userId, plantId),
        ]);
        deviceCategories = setup[0] as Map<String, String>;
        lot237BillingDevice = setup[1] as String;
      }

      // expand(), not map(): a block card row can name several meters at once,
      // and every one of them has to be fetched or the block's total reads as
      // whichever meters happened to be cached.
      final devices = mappings.values
          .where((m) => m.isMapped)
          .expand(_mappedDevices)
          .toSet()
          .toList();
      if (lot237BillingDevice.isNotEmpty) devices.add(lot237BillingDevice);
      if (isLot237 && !devices.contains('VSOLAR')) devices.add('VSOLAR');

      final lot237MainDevice = isLot237
          ? (_m(mappings, 'hero[0]') ?? _m(mappings, 'glance[0]'))?.device ??
              lot237BillingDevice
          : '';
      final billDevices = isLot237
          ? <String>{
              if (lot237MainDevice.isNotEmpty) lot237MainDevice,
              if (lot237BillingDevice.isNotEmpty) lot237BillingDevice,
            }.toList()
          : devices;

      final energyCache = <String, _DeviceEnergy>{};
      final billCache = <String, _TnbBill>{};

      final cacheKey = '$userId|${devices.join(',')}|$isLot237';
      final cached = _readBootstrapCache(cacheKey);
      if (cached != null) {
        energyCache.addAll(cached.energy);
        billCache.addAll(cached.bills);
      } else {
        // Bills don't depend on the energy series — fetch both groups
        // concurrently and only emit the hero partial as soon as energy lands.
        final billsFuture = userId.isNotEmpty
            ? Future.wait([
                ...billDevices.map((d) async {
                  billCache[d] = isLot237
                      ? await _fetchTnbBillSimOnly(d)
                      : await _fetchTnbBill(
                          userId,
                          d,
                          categoryId: deviceCategories[d] ?? '',
                          fastFallback: isLot237,
                        );
                }),
              ])
            : Future.value(<void>[]);
        const batchSize = 12;
        for (var i = 0; i < devices.length; i += batchSize) {
          await Future.wait(
            devices.skip(i).take(batchSize).map((d) async {
              energyCache[d] = await _fetchEnergy(d);
            }),
          );
        }
        if (isFlexiPlant) {
          onProgress?.call(_lot237Partial(
            mappings: mappings,
            energyCache: energyCache,
            billCache: billCache,
            billingDevice: lot237BillingDevice,
          ));
        }
        await billsFuture;
        _saveBootstrapCache(cacheKey, energyCache, billCache);
      }

      if (isFlexiPlant) {
        if (onProgress != null && cached != null) {
          onProgress(_lot237Partial(
            mappings: mappings,
            energyCache: energyCache,
            billCache: billCache,
            billingDevice: lot237BillingDevice,
          ));
        }
        // Poll refresh: KPI-only path — skip chart SQL that freezes the browser.
        if (!includeCharts) {
          final refreshDevices = <String>{};
          final hero0 = _m(mappings, 'hero[0]') ?? _m(mappings, 'glance[0]');
          final hero1 = _m(mappings, 'hero[1]');
          final tnbKwh = _m(mappings, 'tnb.kwh');
          if (hero0 != null && hero0.isMapped) refreshDevices.add(hero0.device);
          if (hero1 != null && hero1.isMapped) refreshDevices.add(hero1.device);
          if (tnbKwh != null && tnbKwh.isMapped)
            refreshDevices.add(tnbKwh.device);
          if (lot237MainDevice.isNotEmpty) refreshDevices.add(lot237MainDevice);
          if (isLot237) refreshDevices.add('VSOLAR');
          for (var i = 0; i < refreshDevices.length; i += 2) {
            await Future.wait(
              refreshDevices.skip(i).take(2).map((d) async {
                energyCache[d] = await _fetchEnergy(d);
              }),
            );
          }
          if (refreshDevices.isNotEmpty) {
            _saveBootstrapCache(cacheKey, energyCache, billCache);
          }
          final result = _lot237Partial(
            mappings: mappings,
            energyCache: energyCache,
            billCache: billCache,
            billingDevice: lot237BillingDevice,
          );
          completer.complete(result);
          return result;
        }
          await _applyGroupPanels(ecConfig, mappings, energyCache);
          final result = await _resolveLot237(
          mappings: mappings,
          userId: userId,
          energyCache: energyCache,
          billCache: billCache,
          billingDevice: lot237BillingDevice,
          deviceCategories: deviceCategories,
          includeCharts: includeCharts,
          onProgress: onProgress,
          // Lot 237's real solar device happens to be literally named
          // 'VSOLAR' — that is not true for any other plant, so only Lot 237
          // gets that fallback; every other flexi plant with no hero[1]
          // mapped shows an unmapped solar card instead of reading Lot
          // 237's device.
          defaultSolarDevice: isLot237 ? 'VSOLAR' : '',
        );
          completer.complete(result);
          return result;
      }

      // A pin with no cost of its own reports nothing. This used to return a
      // hardcoded figure (RM 12,500, RM 8,200 ...) when no total was known, and
      // otherwise a fixed percentage of ANOTHER pin's total — so five unmapped
      // lots displayed invented shares of Lot 237's energy as if measured.
      // _formatRm renders 0 as an em dash, so unmapped pins now read as empty.
      final double Function(int, double) getFallbackCost = (int idx, double total) => 0;

      // Same fabrication for energy — see getFallbackCost above.
      final double Function(int, double) getFallbackEnergy = (int idx, double totalEnergy) => 0;

      final driverKeys = [
        'cost_drivers[0]',
        'cost_drivers[1]',
        'cost_drivers[2]',
        'cost_drivers[3]'
      ];
      final drivers = <PeccCostDriverLive>[];
      double driversCostSum = 0;

      // Hero = plant TNB Bill Simulator total (VDPM002 for Lot 237) — NOT sum of sub-meters.
      final heroEnergyMap = _m(mappings, 'hero.total_energy');
      final heroDevice = heroEnergyMap?.device ?? lot237BillingDevice;
      final heroCategory = deviceCategories[heroDevice] ?? '';
      final heroBill = heroDevice.isNotEmpty
          ? billCache[heroDevice] ??
              await _fetchTnbBill(userId, heroDevice, categoryId: heroCategory)
          : _TnbBill();
      final totalCost = heroBill.totalBill;

      for (final key in driverKeys.take(3)) {
        final map = _m(mappings, key);
        if (map == null || !map.isMapped) continue;
        final cost = billCache[map.device]?.totalBill ?? 0;
        final pct = totalCost > 0 ? (cost / totalCost * 100) : 0.0;

        // Exclude main meter from sub-meter sum to prevent over-subtraction
        if (map.device != heroDevice) {
          driversCostSum += cost;
        }

        drivers.add(PeccCostDriverLive(
          label: map.label,
          costDisplay: _formatRm(cost > 0
              ? cost
              : getFallbackCost(driverKeys.indexOf(key), totalCost)),
          pctDisplay: '${pct.toStringAsFixed(1)}% of total cost',
        ));
      }

      // Cost Driver 4 = "Others" — auto-calculated as remainder of total cost
      final driver4Map = _m(mappings, 'cost_drivers[3]');
      if (driver4Map != null && driver4Map.isMapped) {
        // Explicitly mapped: use its bill
        final cost = billCache[driver4Map.device]?.totalBill ?? 0;
        final pct = totalCost > 0 ? (cost / totalCost * 100) : 0.0;
        drivers.add(PeccCostDriverLive(
          label: driver4Map.label.isNotEmpty ? driver4Map.label : 'Others',
          costDisplay:
              _formatRm(cost > 0 ? cost : getFallbackCost(3, totalCost)),
          pctDisplay: '${pct.toStringAsFixed(1)}% of total cost',
        ));
      } else {
        // Auto-calculate: others = total - known drivers
        double othersCost = totalCost - driversCostSum;
        if (othersCost <= 0) {
          othersCost = getFallbackCost(3, totalCost);
        }
        final pct = totalCost > 0
            ? ((othersCost / totalCost) * 100).clamp(0.0, 100.0)
            : 0.0;
        drivers.add(PeccCostDriverLive(
          label: 'Others',
          costDisplay: _formatRm(othersCost),
          pctDisplay: '${pct.toStringAsFixed(1)}% of total cost',
        ));
      }

      final monthlyKwh = heroEnergyMap != null && heroEnergyMap.isMapped
          ? energyCache[heroEnergyMap.device]?.monthlyKwh ?? 0
          : 0.0;

      final glanceEnergyMap = _m(mappings, 'glance[0]');
      final dailyDevice = glanceEnergyMap?.device ?? heroDevice;
      final dailyKwh = dailyDevice.isNotEmpty
          ? energyCache[dailyDevice]?.dailyKwh ?? 0
          : 0.0;
      final dailyCost = dailyDevice.isNotEmpty
          ? (billCache[dailyDevice] ?? heroBill).estimateDailyCost(dailyKwh)
          : 0.0;

      final mwh = monthlyKwh / 1000;
      final specific = mwh > 0 && totalCost > 0 ? totalCost / mwh : 0.0;

      final pins = <PeccPinLive>[];
      for (var i = 0; i < 4; i++) {
        final map = _m(mappings, driverKeys[i]);
        if (map == null || !map.isMapped) {
          // For pin 3 (Cost Driver 4 / Others), show auto-calculated value
          if (i == 3) {
            final othersDriver = drivers.firstWhere(
              (d) => d.label.toLowerCase().contains('others'),
              orElse: () => const PeccCostDriverLive(
                  label: '', costDisplay: '—', pctDisplay: ''),
            );
            pins.add(PeccPinLive(
              costDisplay: othersDriver.costDisplay,
              energyDisplay: '—',
            ));
          } else {
            pins.add(const PeccPinLive(costDisplay: '—', energyDisplay: '—'));
          }
          continue;
        }
        pins.add(PeccPinLive(
          costDisplay: _formatRm(billCache[map.device]?.totalBill ?? 0),
          energyDisplay:
              _formatEnergy(energyCache[map.device]?.monthlyKwh ?? 0),
        ));
      }

      // Final pass for left panel pins (indices 0-3) to ensure no empty values
      for (int i = 0; i < 4; i++) {
        if (i >= pins.length) {
          pins.add(PeccPinLive(
            costDisplay: _formatRm(getFallbackCost(i, totalCost)),
            energyDisplay: _formatEnergy(getFallbackEnergy(i, monthlyKwh)),
          ));
        } else {
          String costDisp = pins[i].costDisplay;
          String energyDisp = pins[i].energyDisplay;
          if (costDisp == '—' || costDisp.isEmpty) {
            costDisp = _formatRm(getFallbackCost(i, totalCost));
          }
          if (energyDisp == '—' || energyDisp.isEmpty) {
            energyDisp = _formatEnergy(getFallbackEnergy(i, monthlyKwh));
          }
          pins[i] = PeccPinLive(
            costDisplay: costDisp,
            energyDisplay: energyDisp,
          );
        }
      }

      // Group map: resolve all 6 visible map pins (DB has 8 but we skip index 3=CostDriver4 and 7=LOT237C)
      final pinsByIndex = <int, PeccPinLive>{};
      // Every pin the configuration defines, not a fixed six. Adding a cost
      // driver in settings used to save and resolve fine, then never reach the
      // map because both this loop and the widget were hardcoded.
      final pinOrder = <int>[];
      for (final k in mappings.keys) {
        if (!k.startsWith('pin[')) continue;
        final idx = int.tryParse(k.substring(4, k.length - 1));
        if (idx != null) pinOrder.add(idx);
      }
      pinOrder.sort();
      final activePins = pinOrder.isEmpty ? const [0, 1, 2, 4, 5, 6] : pinOrder;

      if (isGroup) {
        for (final i in activePins) {
          final key = 'pin[$i]';
          final map = _m(mappings, key);
          if (map != null && map.isMapped) {
            final cost = billCache[map.device]?.totalBill ?? 0;
            final energy = energyCache[map.device]?.monthlyKwh ?? 0;
            pinsByIndex[i] = PeccPinLive(
              costDisplay: _formatRm(cost),
              energyDisplay: _formatEnergy(energy),
              costRm: cost,
              energyKwh: energy,
              metrics: await _resolvePinMetrics(
                  map,
                  cost,
                  energy,
                  energyCache[map.device]?.dailyCarbonKg ?? 0,
                  billCache[map.device]?.mdChargeRm ?? 0,
                  map.solarDevice.isNotEmpty
                      ? (energyCache[map.solarDevice]?.monthlyKwh ?? 0)
                      : 0),
            );
          }
        }

        // Cost Driver 4 (index 3) auto-calculation fallback


        // Fallback: If Lot 237 pin (index 6) is not explicitly mapped, use the TNB simulator.
        if (!pinsByIndex.containsKey(_lot237PinIndex) &&
            lot237BillingDevice.isNotEmpty) {
          final lotBill = billCache[lot237BillingDevice] ??
              await _fetchTnbBill(
                userId,
                lot237BillingDevice,
                categoryId: deviceCategories[lot237BillingDevice] ?? '',
              );
          pinsByIndex[_lot237PinIndex] = PeccPinLive(
            costRm: lotBill.totalBill,
            energyKwh: energyCache[lot237BillingDevice]?.monthlyKwh ?? 0,
            costDisplay: _formatRm(lotBill.totalBill),
            energyDisplay: _formatEnergy(
                energyCache[lot237BillingDevice]?.monthlyKwh ?? 0),
          );
        }

        // Fallback: If LOT 53A/53B/237 (indices 4,5,6) are unmapped,
        // try fetching from energy cache.
        for (final idx in [4, 5, 6]) {
          if (!pinsByIndex.containsKey(idx)) {
            final fallbackKey = 'pin[$idx]';
            final fMap = _m(mappings, fallbackKey);
            if (fMap != null && fMap.isMapped) {
              final cost = billCache[fMap.device]?.totalBill ?? 0;
              final energy = energyCache[fMap.device]?.monthlyKwh ?? 0;
              if (cost > 0 || energy > 0) {
                pinsByIndex[idx] = PeccPinLive(
                  costRm: cost,
                  energyKwh: energy,
                  costDisplay: _formatRm(cost),
                  energyDisplay: _formatEnergy(energy),
                );
              }
            }
          }
        }

        // Final pass: ensure no visible pin has empty data.
        for (final i in activePins) {
          final existing = pinsByIndex[i];
          if (existing == null) {
            pinsByIndex[i] = PeccPinLive(
              costDisplay: _formatRm(getFallbackCost(i, totalCost)),
              energyDisplay: _formatEnergy(getFallbackEnergy(i, monthlyKwh)),
            );
          } else {
            String costDisp = existing.costDisplay;
            String energyDisp = existing.energyDisplay;
            if (costDisp == '—' || costDisp.isEmpty) {
              costDisp = _formatRm(getFallbackCost(i, totalCost));
            }
            if (energyDisp == '—' || energyDisp.isEmpty) {
              energyDisp = _formatEnergy(getFallbackEnergy(i, monthlyKwh));
            }
            pinsByIndex[i] = PeccPinLive(
              costDisplay: costDisp,
              energyDisplay: energyDisp,
              // Carried over. This pass exists to fill in blank cost/energy
              // text, and rebuilding the entry without the cards silently threw
              // away everything the pin was configured to show.
              metrics: existing.metrics,
              costRm: existing.costRm,
              energyKwh: existing.energyKwh,
            );
          }
        }
      }

      // ── Group summaries aggregate the pins ────────────────────────────
      //
      // The pins are the single source of truth: the panel down the left is
      // the sum of the sites, so a site's figure appears in exactly one place
      // and the total always equals what is drawn beside it. Until now the
      // headline came from one hero device's TNB bill while the pins came from
      // their own meters, so the two could disagree with nothing on screen to
      // explain why.
      //
      // Only used when pins are actually mapped. A dashboard whose pins nobody
      // has set up keeps the previous behaviour rather than dropping to zero.
      double groupCost = totalCost;
      double groupKwh = monthlyKwh;
      double groupDailyKwh = dailyKwh;
      double groupDailyCost = dailyCost;
      double groupSolarKwh = 0;
      double groupMdRm = 0;
      double groupCarbonKg = 0;

      // Kept per site so the right rail can rank them: a ranking needs the
      // individual figures, not the total. Declared out here because the
      // rankings are built after the summing block closes.
      final perSite = <({
        String name,
        double cost,
        double energy,
        double solar,
        double carbon,
        double md
      })>[];

      if (isGroup) {
        double costSum = 0;
        double kwhSum = 0;
        double dailyKwhSum = 0;
        double dailyCostSum = 0;
        var mappedPins = 0;
        final counted = <String>{};

        for (final i in activePins) {
          final map = _m(mappings, 'pin[$i]');
          if (map == null || !map.isMapped) continue;
          // Two pins pointed at the same meter would otherwise be added twice.
          if (!counted.add(map.device)) continue;
          mappedPins++;
          final bill = billCache[map.device];
          final energy = energyCache[map.device];
          costSum += bill?.totalBill ?? 0;
          kwhSum += energy?.monthlyKwh ?? 0;
          dailyKwhSum += energy?.dailyKwh ?? 0;
          dailyCostSum += bill?.estimateDailyCost(energy?.dailyKwh ?? 0) ?? 0;
          groupCarbonKg += energy?.dailyCarbonKg ?? 0;

          // MD charges need no request: the bill above already breaks the
          // total down. Solar is deliberately not read from this meter — a
          // cost driver points at a site's main incoming meter, and summing
          // its hourly energy produced a "solar generation" figure that was
          // really just that meter's own consumption.
          groupMdRm += bill?.mdChargeRm ?? 0;

          // Solar for this site, from its own solar device when one is named.
          var siteSolarKwh = 0.0;
          if (map.solarDevice.isNotEmpty) {
            final solarEnergy = energyCache[map.solarDevice] ??
                await _fetchEnergy(map.solarDevice);
            energyCache[map.solarDevice] = solarEnergy;
            siteSolarKwh = solarEnergy.monthlyKwh;
            groupSolarKwh += siteSolarKwh;
          }

          perSite.add((
            name: map.label.isNotEmpty ? map.label : map.device,
            cost: bill?.totalBill ?? 0,
            energy: energy?.monthlyKwh ?? 0,
            solar: siteSolarKwh,
            carbon: energy?.dailyCarbonKg ?? 0,
            md: bill?.mdChargeRm ?? 0,
          ));
        }

        if (mappedPins > 0) {
          if (costSum > 0) groupCost = costSum;
          if (kwhSum > 0) groupKwh = kwhSum;
          if (dailyKwhSum > 0) groupDailyKwh = dailyKwhSum;
          if (dailyCostSum > 0) groupDailyCost = dailyCostSum;
        }
      }

      // Positions typed in settings, converted to fractions once here so the
      // widget never has to know they were entered as percentages.
      final pinPositions = <int, ({double x, double y})>{};
      if (isGroup) {
        for (final entry in mappings.entries) {
          if (!entry.key.startsWith('pin[')) continue;
          final idx = int.tryParse(
              entry.key.substring(4, entry.key.length - 1));
          final x = entry.value.xPct;
          final y = entry.value.yPct;
          if (idx == null || x == null || y == null) continue;
          pinPositions[idx] =
              (x: (x / 100).clamp(0.0, 1.0), y: (y / 100).clamp(0.0, 1.0));
        }
      }

      // Group solar comes from the solar device the configuration names, not
      // from the cost-driver meters, which measure incoming grid energy.
      final solarMap = _m(mappings, 'hero.solar_saving');
      var solarSourceLabel = '';
      if (isGroup &&
          groupSolarKwh == 0 &&
          solarMap != null &&
          solarMap.isMapped) {
        final solarEnergy = energyCache[solarMap.device] ??
            await _fetchEnergy(solarMap.device);
        energyCache[solarMap.device] = solarEnergy;
        groupSolarKwh = solarEnergy.monthlyKwh;
        solarSourceLabel =
            solarMap.label.isNotEmpty ? solarMap.label : solarMap.device;
      }

      // Rankings. Only sites that actually reported the metric take part, so a
      // rail never announces a winner among nothing.
      final rankings = <String, ({String site, String value})>{};
      void rank(
        String id,
        double Function(({String name, double cost, double energy, double solar, double carbon, double md})) pick,
        String Function(double) fmt, {
        bool highest = true,
      }) {
        final entries = perSite.where((s) => pick(s) > 0).toList();
        if (entries.isEmpty) return;
        entries.sort((a, b) =>
            highest ? pick(b).compareTo(pick(a)) : pick(a).compareTo(pick(b)));
        rankings[id] =
            (site: entries.first.name, value: fmt(pick(entries.first)));
      }

      rank('cost', (s) => s.cost, _formatRm);
      // Rank the sites that have a solar device of their own.
      rank('saving', (s) => s.solar, _formatEnergy);
      rank('solar', (s) => s.solar, _formatEnergy);

      // Only when no site has one does the group's solar device stand in, shown
      // against the source it came from rather than credited to a site that
      // never measured it. This used to replace the ranking above rather than
      // back it up, so the moment a pin got its own solar device both cards
      // went blank.
      if (!rankings.containsKey('solar') &&
          groupSolarKwh > 0 &&
          solarSourceLabel.isNotEmpty) {
        final fallback = (
          site: solarSourceLabel,
          value: _formatEnergy(groupSolarKwh)
        );
        rankings['saving'] = fallback;
        rankings['solar'] = fallback;
      }
      rank('carbon', (s) => s.carbon,
          (v) => '${_formatNum(v / 1000, 1)} tCO2e');
      // Efficiency is cost per MWh, and lower is better — the one ranking here
      // that is not simply "the biggest number wins".
      final efficient = perSite
          .where((s) => s.energy > 0 && s.cost > 0)
          .map((s) => (name: s.name, rate: s.cost / (s.energy / 1000)))
          .toList()
        ..sort((a, b) => a.rate.compareTo(b.rate));
      if (efficient.isNotEmpty) {
        rankings['efficiency'] = (
          site: efficient.first.name,
          value: '${_formatRm(efficient.first.rate)} / MWh'
        );
      }

      // ── Configured panels ─────────────────────────────────────────────
      //
      // Each card names a pin metric and how to reduce it across the sites, so
      // "is the headline a total or one site's figure?" is answered in
      // settings rather than decided here.
      final panelCards = <String, List<PeccPanelCardLive>>{};
      // Top-level when the API keeps it, nested under branding otherwise — the
      // Cloud Function drops top-level fields it does not recognise, which is
      // why the settings page writes both.
      final panelCfg = (ecConfig['panels'] is Map
              ? Map<String, dynamic>.from(ecConfig['panels'] as Map)
              : (ecConfig['branding'] is Map &&
                      (ecConfig['branding'] as Map)['panels'] is Map
                  ? Map<String, dynamic>.from(
                      ((ecConfig['branding'] as Map)['panels']) as Map)
                  : const <String, dynamic>{}))
          .cast<String, dynamic>();

      if (isGroup && panelCfg.isNotEmpty && perSite.isNotEmpty) {
        double valueOf(
            ({String name, double cost, double energy, double solar, double carbon, double md}) s,
            String metric) {
          switch (metric) {
            case 'cost':
              return s.cost;
            case 'energy':
              return s.energy;
            case 'solar':
              return s.solar;
            case 'carbon':
              return s.carbon;
            case 'md_charges':
              return s.md;
            default:
              return 0;
          }
        }

        /// [unit] is the unit typed into the panel's settings. Empty means the
        /// metric decides, which is what every configuration did before the
        /// field existed — so those keep formatting exactly as they did. Given
        /// one, the number is written plainly and that unit follows it, which
        /// is the only way the same figure can be shown as MWh or RM '000
        /// without changing what is measured.
        String format(String metric, double v, [String unit = '']) {
          if (unit.isNotEmpty) {
            final decimals = switch (metric) {
              'carbon' => 1,
              'pf' => 3,
              'cost' || 'md_charges' || 'energy' || 'solar' => 0,
              _ => 2,
            };
            return '${_formatNum(v, decimals)} $unit';
          }
          switch (metric) {
            case 'cost':
            case 'md_charges':
              return _formatRm(v);
            case 'energy':
            case 'solar':
              return _formatEnergy(v);
            case 'carbon':
              return '${_formatNum(v / 1000, 1)} tCO2e';
            default:
              return _formatNum(v, 2);
          }
        }

        for (final entry in panelCfg.entries) {
          final rows = entry.value as List<dynamic>? ?? const [];
          final cards = <PeccPanelCardLive>[];
          for (final r in rows.whereType<Map>()) {
            final j = r.cast<String, dynamic>();
            final metric = j['metricKey']?.toString() ?? '';
            final label = j['label']?.toString() ?? '';
            final key = j['key']?.toString() ?? '';
            // Typed into the panel's UNIT column. Empty leaves the metric's own
            // formatting alone.
            final unit = j['unit']?.toString().trim() ?? '';
            final values = perSite.map((s) => valueOf(s, metric)).toList();
            final reporting = values.where((v) => v > 0).toList();
            final groupOnlySolar = metric == 'solar' && groupSolarKwh > 0;
            if (reporting.isEmpty && !groupOnlySolar) {
              cards.add(PeccPanelCardLive(key: key, label: label, value: '—'));
              continue;
            }
            if (reporting.isEmpty && groupOnlySolar && entry.key != 'right') {
              cards.add(PeccPanelCardLive(
                  key: key, label: label, value: _formatEnergy(groupSolarKwh)));
              continue;
            }

            // Same fallback, and same condition: only when no site reports it.
            if (entry.key == 'right' &&
                metric == 'solar' &&
                reporting.isEmpty &&
                groupSolarKwh > 0 &&
                solarSourceLabel.isNotEmpty) {
              cards.add(PeccPanelCardLive(
                key: key,
                label: label,
                value: _formatEnergy(groupSolarKwh),
                site: solarSourceLabel,
              ));
              continue;
            }

            if (entry.key == 'right') {
              // Ranked: the winning site, not a combined figure.
              final highest = (j['rankBy']?.toString() ?? 'highest') == 'highest';
              final ordered = perSite.where((s) => valueOf(s, metric) > 0).toList()
                ..sort((a, b) => highest
                    ? valueOf(b, metric).compareTo(valueOf(a, metric))
                    : valueOf(a, metric).compareTo(valueOf(b, metric)));
              cards.add(PeccPanelCardLive(
                key: key,
                label: label,
                value: format(metric, valueOf(ordered.first, metric), unit),
                site: ordered.first.name,
              ));
              continue;
            }

            final agg = j['agg']?.toString() ?? 'sum';
            double reduced;
            switch (agg) {
              case 'avg':
                reduced =
                    reporting.reduce((a, b) => a + b) / reporting.length;
                break;
              case 'max':
                reduced = reporting.reduce((a, b) => a > b ? a : b);
                break;
              case 'min':
                reduced = reporting.reduce((a, b) => a < b ? a : b);
                break;
              default:
                reduced = reporting.reduce((a, b) => a + b);
            }
            cards.add(PeccPanelCardLive(
                key: key, label: label, value: format(metric, reduced, unit)));
          }
          if (cards.isNotEmpty) panelCards[entry.key] = cards;
        }
      }

      final groupMwh = groupKwh / 1000;
      final groupSpecific =
          groupMwh > 0 && groupCost > 0 ? groupCost / groupMwh : specific;

      final hasData = groupCost > 0 || groupKwh > 0 || groupDailyKwh > 0;

      final result = PeccLiveData(
        totalCostMtd: _formatRm(groupCost),
        totalEnergyMtd: _formatEnergy(groupKwh),
        specificCost:
            groupSpecific > 0 ? '${_formatRm(groupSpecific)} /MWh' : '—',
        costDrivers: drivers,
        energyToday: _formatKwh(groupDailyKwh),
        energyCostToday: _formatRm(groupDailyCost),
        // A dash where there is genuinely nothing, rather than a number that
        // was never measured.
        rankings: rankings,
        panelCards: panelCards,
        solarToday: groupSolarKwh > 0 ? _formatEnergy(groupSolarKwh) : '—',
        solarSharePct: (groupSolarKwh > 0 && groupKwh > 0)
            ? '${(groupSolarKwh / groupKwh * 100).toStringAsFixed(1)}%'
            : '—',
        groupSolar: groupSolarKwh > 0 ? _formatEnergy(groupSolarKwh) : '—',
        groupMdCharges: groupMdRm > 0 ? _formatRm(groupMdRm) : '—',
        groupCarbon: groupCarbonKg > 0
            ? '${_formatNum(groupCarbonKg / 1000, 1)} tCO2e'
            : '—',
        pins: pins,
        pinsByIndex: pinsByIndex,
        pinOrder: activePins.toList(),
        pinPositions: pinPositions,
        hasData: hasData,
      );
      completer.complete(result);
      return result;
    } catch (e, s) {
      completer.completeError(e, s);
      rethrow;
    } finally {
      _resolveInFlight = false;
      _resolveInFlightFuture = null;
    }
  }

  /// Contract MD (kW) from TNB Meter Setting — mirrors Max Demand Monitoring.
  static Future<double> _contractKwFromTnbMeter(String deviceId) async {
    if (deviceId.isEmpty) return 0;
    final contracts = await _loadTnbMeterContracts('');
    return contracts[deviceId] ?? 0;
  }

  static Future<List<Map<String, dynamic>>> _loadTnbMeterData(
      String userId) async {
    final key = userId;
    final now = DateTime.now();
    final cachedAt = _tnbMeterDataAt[key];
    if (_tnbMeterData.containsKey(key) &&
        cachedAt != null &&
        now.difference(cachedAt) < const Duration(minutes: 5)) {
      return _tnbMeterData[key]!;
    }
    return _tnbMeterDataRequests.putIfAbsent(key, () async {
      try {
        // TNB meters are shared across every user of this client, not
        // per-login — no userId filter.
        final res = await http
            .get(Uri.parse('$_dataBase/tnbMeters'),
                headers: AppConfig.headers)
            .timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) return <Map<String, dynamic>>[];
        final rawList = jsonDecode(res.body);
        if (rawList is! List) return <Map<String, dynamic>>[];
        final list = <Map<String, dynamic>>[];
        for (final raw in rawList) {
          if (raw is Map<String, dynamic>) {
            list.add(raw);
          }
        }
        _tnbMeterData[key] = list;
        _tnbMeterDataAt[key] = DateTime.now();
        return list;
      } catch (_) {
        return <Map<String, dynamic>>[];
      } finally {
        _tnbMeterDataRequests.remove(key);
      }
    });
  }

  static Future<Map<String, double>> _loadTnbMeterContracts(
      String userId) async {
    final out = <String, double>{};
    final list = await _loadTnbMeterData(userId);
    for (final raw in list) {
      final md = _toDouble(raw['contractMdKw']);
      if (md <= 0) continue;
      final tag = raw['influxDbTag']?.toString().trim() ?? '';
      final code = raw['meterCode']?.toString().trim() ?? '';
      if (tag.isNotEmpty) out[tag] = md;
      if (code.isNotEmpty) out[code] = md;
    }
    return out;
  }

  /// device_id → tariffCategoryId from TNB Meter Setting.
  static Future<Map<String, String>> _loadTnbMeterCategories(
      String userId) async {
    final out = <String, String>{};
    final list = await _loadTnbMeterData(userId);
    for (final raw in list) {
      final tag = raw['influxDbTag']?.toString().trim() ?? '';
      final code = raw['meterCode']?.toString().trim() ?? '';
      final cat = raw['tariffCategoryId']?.toString().trim() ?? '';
      if (tag.isNotEmpty && cat.isNotEmpty) out[tag] = cat;
      if (code.isNotEmpty && cat.isNotEmpty) out[code] = cat;
    }
    return out;
  }

  /// Billing device (DPM ID) for a factory name from TNB Meter Setting.
  static Future<String> _lotBillingDevice(String userId, String lotName) async {
    try {
      final list = await _loadTnbMeterData(userId);
      final target = lotName.trim().toLowerCase();
      for (final raw in list) {
        final label = raw['meterLabel']?.toString().toLowerCase() ?? '';
        final code = raw['meterCode']?.toString().toLowerCase() ?? '';
        final plant = raw['plantId']?.toString().toLowerCase() ?? '';
        if (!label.contains(target) &&
            !code.contains(target) &&
            !plant.contains(target.replaceAll(' ', ''))) continue;
        final tag = raw['influxDbTag']?.toString().trim() ?? '';
        if (tag.isNotEmpty) return tag;
      }
      return 'VDPM002';
    } catch (_) {
      return 'VDPM002';
    }
  }

  /// Turns a pin's configured cards into values.
  ///
  /// Cost and energy come from figures this resolve already fetched, so the
  /// common case costs nothing extra. The rest are fetched only when a pin
  /// actually asks for them — six pins each blindly pulling max demand, solar
  /// and power factor would be eighteen more requests on every dashboard load,
  /// almost all of them for cards nobody configured.
  /// Thousands separators plus the requested decimals. The card's own setting
  /// decides how precise the figure looks, which is a presentation choice and
  /// not something the fetch should hardcode.
  static String _formatNum(double v, int decimals) {
    final fixed = v.toStringAsFixed(decimals);
    final parts = fixed.split('.');
    final digits = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return parts.length > 1 ? '${buf.toString()}.${parts[1]}' : buf.toString();
  }

  static Future<List<PeccPinMetric>> _resolvePinMetrics(
    _PeccMapping map,
    double costRm,
    double monthlyKwh,
    double energyCarbonKg,
    double mdChargeRm,
    double solarKwh,
  ) async {
    if (map.metricSpecs.isEmpty) return const [];

    final out = <PeccPinMetric>[];
    for (final spec in map.metricSpecs) {
      final metricKey = spec['metricKey']?.toString() ?? '';
      final colorKey = spec['colorKey']?.toString() ?? 'cyan';
      final typedLabel = spec['label']?.toString().trim() ?? '';
      final decimals =
          spec['decimals'] is num ? (spec['decimals'] as num).toInt() : null;

      String label;
      String value;
      String unit;
      // The unrounded figure behind the text, so totals add what is shown.
      var amount = 0.0;

      switch (metricKey) {
        case 'cost':
          label = 'Total Energy Cost';
          value = _formatRm(costRm);
          amount = costRm;
          unit = '';
          break;
        case 'energy':
          label = 'Total Energy Consumption';
          value = _formatEnergy(monthlyKwh);
          amount = monthlyKwh;
          unit = '';
          break;
        case 'max_demand':
          final kw = await _fetchLastMonthMaxDemandKw(map.device);
          label = 'Max Demand (MD)';
          value = kw > 0 ? _formatNum(kw, decimals ?? 0) : '—';
          amount = kw;
          unit = kw > 0 ? 'kW' : '';
          break;
        case 'md_charges':
          // From the billing endpoint's own breakdown, which is where the
          // billing screens get it. Working it out here from max demand and a
          // tariff rate would be a second calculation, free to drift from the
          // first.
          label = 'MD Charges';
          value = mdChargeRm > 0 ? _formatRm(mdChargeRm) : '—';
          amount = mdChargeRm;
          unit = '';
          break;
        case 'solar':
          // From this site's own solar device. A cost driver points at the
          // incoming meter, so reading solar off that reported grid import
          // under a solar heading.
          label = 'Total Solar Generation';
          value = solarKwh > 0 ? _formatNum(solarKwh, decimals ?? 0) : '—';
          amount = solarKwh;
          unit = solarKwh > 0 ? 'kWh' : '';
          break;
        case 'carbon':
          final carbonKg = energyCarbonKg;
          label = 'Carbon Emission';
          value =
              carbonKg > 0 ? _formatNum(carbonKg / 1000, decimals ?? 1) : '—';
          amount = carbonKg;
          unit = carbonKg > 0 ? 'tCO2e' : '';
          break;
        case 'pf':
          final pf = await _fetchLatestPowerFactorMysql(map.device);
          label = 'Avg Power Factor';
          value = pf > 0 ? _formatNum(pf, decimals ?? 3) : '—';
          amount = pf;
          unit = '';
          break;
        default:
          // An unknown key means settings offers something this resolver has
          // not learned yet. Skipping keeps the card off the dashboard rather
          // than drawing a blank one.
          continue;
      }

      out.add(PeccPinMetric(
        metricKey: metricKey,
        label: typedLabel.isNotEmpty ? typedLabel : label,
        value: value,
        unit: unit,
        colorKey: colorKey,
        amount: amount,
      ));
    }
    return out;
  }

  static Future<_TnbBill> _fetchTnbBillSimOnly(String deviceId) async {
    final out = _TnbBill();
    if (deviceId.isEmpty) return out;
    final sim = await _fetchTnbSimulator(deviceId);
    out.totalBill =
        _toDouble(sim['total_bill'] ?? sim['totalBill'] ?? sim['total_amount']);
    out.totalUsageKwh = _toDouble(sim['total_usage_kWh'] ??
        sim['energy_consumption_kWh'] ??
        sim['totalKwh']);
    return out;
  }

  static Future<_DeviceEnergy> _fetchEnergy(String deviceId,
      {String? date}) async {
    if (date == null || date.isEmpty) {
      final cached = _energyCache[deviceId];
      final cachedAt = _energyCacheAt[deviceId];
      if (cached != null &&
          cachedAt != null &&
          DateTime.now().difference(cachedAt).inSeconds < 180) {
        return cached;
      }
    }
    final out = _DeviceEnergy();
    try {
      final uri = Uri.parse(
        '$_dataBase/energyDetails/total/${Uri.encodeComponent(deviceId)}',
      ).replace(queryParameters: {
        if (date != null && date.isNotEmpty) 'date': date,
      });
      // 15s, not 6. This endpoint regularly takes longer than six seconds and
      // the old limit turned a slow answer into a zero, which the panels then
      // drew as an em dash — a site reading "no data" when the figure existed
      // and was simply late.
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return out;
      final body = jsonDecode(res.body);
      if (body is! List) return out;
      for (final row in body) {
        if (row is! Map) continue;
        final period = row['period']?.toString() ?? '';
        final val = _toDouble(row['total_energy']);
        if (period == 'daily') {
          out.dailyKwh = val;
          out.dailyCarbonKg = _toDouble(row['daily_emission']);
        }
        if (period == 'monthly') out.monthlyKwh = val;
      }
      if (date == null || date.isEmpty) {
        _energyCache[deviceId] = out;
        _energyCacheAt[deviceId] = DateTime.now();
      }
    } catch (_) {}
    return out;
  }

  /// Full TNB Bill Simulator total — same as "CURRENT MONTH ACCRUAL" / TOTAL BEFORE REBATES.
  /// uid that owns this tenant's published dashboards, and therefore its TNB
  /// tariff. Billing config is not always stored under the shared owner or
  /// under the logged-in user: on this tenant it sits under the admin who set
  /// it up, so a non-admin viewer resolved no tariff and every cost read as an
  /// em dash. Looked up once per session from the same /kanban-settings/list
  /// the dashboard already uses to find a fallback admin.
  static String? _cachedTariffOwner;

  static Future<String> _tariffOwnerUid() async {
    final cached = _cachedTariffOwner;
    if (cached != null) return cached;
    var owner = '';
    try {
      final res = await http
          .get(Uri.parse('$_dataBase/kanban-settings/list'),
              headers: AppConfig.headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        for (final raw in body['data'] as List<dynamic>? ?? const []) {
          final id = (raw is Map ? raw['userId'] : null)?.toString() ?? '';
          if (id.isNotEmpty) {
            owner = id;
            break;
          }
        }
      }
    } catch (_) {}
    _cachedTariffOwner = owner;
    return owner;
  }

  static Future<_TnbBill> _fetchTnbBill(
    String userId,
    String deviceId, {
    String categoryId = '',
    bool fastFallback = false,
  }) async {
    final cacheKey = '$userId|$deviceId|$categoryId';
    final cached = _billCache[cacheKey];
    final cachedAt = _billCacheAt[cacheKey];
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt).inSeconds < 300) {
      return cached;
    }

    final out = _TnbBill();
    try {
      final now = DateTime.now();
      final params = <String, String>{
        'device_id': deviceId,
        if (categoryId.isNotEmpty) 'category_id': categoryId,
      };
      // Billing config/simulator lookups are shared across every user of
      // this client, not per-login — see AppConfig.sharedConfigOwnerId.
      // The tariff can be stored either under the shared owner or under the
      // admin who configured it. Querying only 'shared' returned "No
      // electricity tariff found" for tenants whose tariff sits under their own
      // uid, so the bill came back 0 and the hero card showed an em dash even
      // though the mapping and the tariff both existed.
      final adminOwner = await _tariffOwnerUid();
      for (final ownerId in <String>{
        AppConfig.sharedConfigOwnerId,
        if (userId.isNotEmpty) userId,
        if (adminOwner.isNotEmpty) adminOwner,
      }) {
        final uri = Uri.parse(
          '$_dataBase/tnbE3Simulator/bill-total/$ownerId/${now.year}/${now.month}',
        ).replace(queryParameters: params);
        final res = await http
            .get(uri, headers: AppConfig.headers)
            .timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) continue;
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        out.totalBill = _toDouble(body['totalBill'] ?? body['total_amount']);
        out.totalUsageKwh =
            _toDouble(body['total_usage_kWh'] ?? body['totalKwh']);
        out.mdChargeRm = _toDouble(body['mdAmount']);
        if (out.totalBill > 0) {
          _billCache[cacheKey] = out;
          _billCacheAt[cacheKey] = DateTime.now();
          return out;
        }
      }
    } catch (_) {}

    if (fastFallback) {
      final sim = await _fetchTnbSimulator(deviceId);
      out.totalBill = _toDouble(
          sim['total_bill'] ?? sim['totalBill'] ?? sim['total_amount']);
      out.totalUsageKwh = _toDouble(sim['total_usage_kWh'] ??
          sim['energy_consumption_kWh'] ??
          sim['totalKwh']);
      if (out.totalBill > 0 || out.totalUsageKwh > 0) {
        _billCache[cacheKey] = out;
        _billCacheAt[cacheKey] = DateTime.now();
        return out;
      }
    }

    final calculated =
        await _computeTnbBillLocally(userId, deviceId, categoryId: categoryId);
    if (calculated.totalBill > 0) {
      _billCache[cacheKey] = calculated;
      _billCacheAt[cacheKey] = DateTime.now();
    }
    return calculated;
  }

  static int _pfSteps(double upper, double lower) {
    if (upper <= lower) return 0;
    return ((upper - lower) * 100).round();
  }

  static Future<_TnbBill> _computeTnbBillLocally(
    String userId,
    String deviceId, {
    String categoryId = '',
  }) async {
    final out = _TnbBill();
    try {
      final now = DateTime.now();
      final y = now.year;
      final m = now.month;

      // Billing config is shared across every user of this client, not
      // per-login — see AppConfig.sharedConfigOwnerId.
      final billingUri = categoryId.isNotEmpty
          ? '$_dataBase/masterBillingConfig/${AppConfig.sharedConfigOwnerId}/$categoryId'
          : '$_dataBase/masterBillingConfig/${AppConfig.sharedConfigOwnerId}/active';

      Map<String, dynamic>? billingRoot = _masterBillingCache[billingUri];
      final billingCachedAt = _masterBillingCacheAt[billingUri];
      if (billingRoot == null ||
          billingCachedAt == null ||
          DateTime.now().difference(billingCachedAt) >=
              const Duration(minutes: 5)) {
        final billingRes = await http
            .get(Uri.parse(billingUri), headers: AppConfig.headers)
            .timeout(const Duration(seconds: 12));
        if (billingRes.statusCode == 200) {
          billingRoot = jsonDecode(billingRes.body) as Map<String, dynamic>;
          _masterBillingCache[billingUri] = billingRoot;
          _masterBillingCacheAt[billingUri] = DateTime.now();
        }
      }
      if (billingRoot == null) return out;

      final results = await Future.wait([
        http
            .get(
              Uri.parse(
                  '$_dataBase/energyComparison/tnb-bill-simulator/$deviceId'),
              headers: AppConfig.headers,
            )
            .timeout(const Duration(seconds: 12)),
        http
            .get(
              Uri.parse(
                '$_dataBase/tnbE3Simulator/usage-unit/${AppConfig.sharedConfigOwnerId}/$y/$m?device_id=${Uri.encodeComponent(deviceId)}',
              ),
              headers: AppConfig.headers,
            )
            .timeout(const Duration(seconds: 12)),
      ]);

      final tnbSimRes = results[0];
      final usageRes = results[1];
      if (usageRes.statusCode != 200) return out;

      final cfg = billingRoot['config'] as Map<String, dynamic>? ?? billingRoot;

      final tnbSim = tnbSimRes.statusCode == 200
          ? jsonDecode(tnbSimRes.body) as Map<String, dynamic>
          : <String, dynamic>{};
      final usage = jsonDecode(usageRes.body) as Map<String, dynamic>;

      final peakUsage =
          _toDouble(usage['peak_usage_kWh'] ?? tnbSim['peak_usage_kWh']);
      final offPeakUsage = _toDouble(
          usage['off_peak_usage_kWh'] ?? tnbSim['off_peak_usage_kWh']);
      final peakRate = _toDouble(usage['peak_rate']);
      final offPeakRate = _toDouble(usage['off_peak_rate']);
      var peakAmount = _toDouble(usage['peak_amount']);
      var offPeakAmount = _toDouble(usage['off_peak_amount']);
      if (peakAmount <= 0) peakAmount = peakUsage * peakRate;
      if (offPeakAmount <= 0) offPeakAmount = offPeakUsage * offPeakRate;

      final maxDemandKw = _toDouble(tnbSim['max_demand_kW']);
      var pfValue =
          _toDouble(tnbSim['power_factor'] ?? tnbSim['power_factor_avg']);
      pfValue = pfValue.clamp(0.0, 1.0);

      final mdCapacity = _toDouble(cfg['mdCapacityCharge']);
      final mdNetwork = _toDouble(cfg['mdNetworkCharge']);
      final currentAfa = _toDouble(cfg['currentAFA']);
      final tier1Threshold = _toDouble(cfg['targetThreshold']) > 0
          ? _toDouble(cfg['targetThreshold'])
          : 0.98;
      final tier1Rate =
          _toDouble(cfg['tier1Rate']) > 0 ? _toDouble(cfg['tier1Rate']) : 1.5;
      final tier2Trigger = _toDouble(cfg['tier2Trigger']) > 0
          ? _toDouble(cfg['tier2Trigger'])
          : 0.96;
      final tier2Rate =
          _toDouble(cfg['tier2Rate']) > 0 ? _toDouble(cfg['tier2Rate']) : 3.0;

      final totalKwh = peakUsage + offPeakUsage;
      final mdAmount = maxDemandKw * (mdCapacity + mdNetwork);
      final icptAmount = totalKwh * currentAfa;

      var pfPenaltyAmount = 0.0;
      if (pfValue < tier1Threshold) {
        final tier1Lower = pfValue > tier2Trigger ? pfValue : tier2Trigger;
        final tier1Penalty = _pfSteps(tier1Threshold, tier1Lower) * tier1Rate;
        var tier2Penalty = 0.0;
        if (pfValue < tier2Trigger) {
          tier2Penalty = _pfSteps(tier2Trigger, pfValue) * tier2Rate;
        }
        final pfPenaltyPercent = tier1Penalty + tier2Penalty;
        final billingBeforePf =
            peakAmount + offPeakAmount + mdAmount + icptAmount;
        pfPenaltyAmount = billingBeforePf * (pfPenaltyPercent / 100);
      }

      out.totalBill =
          peakAmount + offPeakAmount + mdAmount + pfPenaltyAmount + icptAmount;
      out.totalUsageKwh = totalKwh;
    } catch (_) {}
    return out;
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _addThousands(String digits) {
    final parts = digits.split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    if (parts.length > 1) return '${buf.toString()}.${parts[1]}';
    return buf.toString();
  }

  static String _formatRm(double v) {
    if (v <= 0) return '—';
    return 'RM ${_addThousands(v.round().toString())}';
  }

  static String _formatKwh(double v) {
    if (v <= 0) return '—';
    if (v >= 1000) return '${_addThousands((v / 1000).toStringAsFixed(1))} MWh';
    return '${_addThousands(v.round().toString())} kWh';
  }

  static String _formatEnergy(double kwh) {
    if (kwh <= 0) return '—';
    if (kwh >= 1000)
      return '${_addThousands((kwh / 1000).toStringAsFixed(1))} MWh';
    return '${_addThousands(kwh.round().toString())} kWh';
  }

  static String _formatKwhRaw(double v) {
    if (v <= 0) return '—';
    return _addThousands(v.round().toString());
  }

  static String _formatMwFromKw(double kw) {
    if (kw <= 0) return '—';
    if (kw >= 1000) return '${_addThousands(kw.round().toString())} kWh';
    return '${kw.toStringAsFixed(1)} kWh';
  }

  static double _parseMw(String? display) {
    if (display == null || display == '—') return 0;
    final m = RegExp(r'([\d.]+)').firstMatch(display);
    return m != null ? double.tryParse(m.group(1)!) ?? 0 : 0;
  }

  static String _formatDeltaPct(double today, double yesterday) {
    if (today <= 0 || yesterday <= 0) return '—';
    final pct = (today - yesterday) / yesterday * 100;
    final sign = pct >= 0 ? '+' : '';
    return '$sign${pct.toStringAsFixed(1)}%';
  }

  static PeccHeroDelta _heroDelta(double today, double yesterday,
      {bool lowerIsBetter = false}) {
    if (today <= 0 || yesterday <= 0) return const PeccHeroDelta();
    final pct = (today - yesterday) / yesterday * 100;
    final sign = pct >= 0 ? '+' : '';
    final favorable = lowerIsBetter ? pct <= 0 : pct >= 0;
    return PeccHeroDelta(
        text: '$sign${pct.toStringAsFixed(1)}%', favorable: favorable);
  }

  static Future<Map<String, dynamic>> _fetchTnbSimulator(
      String deviceId) async {
    try {
      final res = await http
          .get(
              Uri.parse(
                  '$_dataBase/energyComparison/tnb-bill-simulator/$deviceId'),
              headers: AppConfig.headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200)
        return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    return {};
  }

  /// Last month's max demand (kW) — same year-on-year logic as Max Demand Monitoring.
  static Future<double> _fetchLastMonthMaxDemandKw(String deviceId) async {
    if (deviceId.isEmpty) return 0;
    try {
      final res = await http
          .get(
            Uri.parse(
                '$_dataBase/energyDetails/year-on-year-analysis?device_id=${Uri.encodeQueryComponent(deviceId)}'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return 0;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as List?) ?? [];
      if (data.isEmpty) return 0;

      double readVal(Map m) => _toDouble(m['current_period_max_demand_kW']);

      final nowMonth = DateTime.now().month;
      final prevMonth = nowMonth == 1 ? 12 : nowMonth - 1;

      for (final raw in data) {
        if (raw is! Map) continue;
        if (raw['month'] == prevMonth) {
          final v = readVal(raw);
          if (v > 0) return v;
        }
      }
      for (var step = 1; step <= 12; step++) {
        final target = ((nowMonth - 1 - step) % 12 + 12) % 12 + 1;
        for (final raw in data) {
          if (raw is! Map || raw['month'] != target) continue;
          final v = readVal(raw);
          if (v > 0) return v;
        }
      }
    } catch (_) {}
    return 0;
  }

  /// Active emission factor (kgCO2e/kWh) from Emission Factor Management.
  static double? _cachedEmissionFactor;
  static DateTime? _emissionFactorCachedAt;

  static Future<double> _fetchActiveEmissionFactor() async {
    final cachedAt = _emissionFactorCachedAt;
    if (_cachedEmissionFactor != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(minutes: 10)) {
      return _cachedEmissionFactor!;
    }
    try {
      final uri = Uri.parse('$_dataBase/emission-factors?status=active');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return _cachedEmissionFactor ?? 0;
      final list = jsonDecode(res.body);
      if (list is! List || list.isEmpty) return _cachedEmissionFactor ?? 0;
      final first = list.first;
      if (first is! Map) return _cachedEmissionFactor ?? 0;
      final factor = _toDouble(first['factor']);
      if (factor > 0) {
        _cachedEmissionFactor = factor;
        _emissionFactorCachedAt = DateTime.now();
      }
      return factor;
    } catch (_) {
      return _cachedEmissionFactor ?? 0;
    }
  }

  /// Today's hourly kWh buckets from Overall_hourly_energy_consumption (via energyComparison/hourly).
  /// Used for Peak/Off-Peak cost split.
  static Future<List<({int hour, double kwh})>> _fetchHourlyKwhToday(
      String deviceId) async {
    if (deviceId.isEmpty) return [];
    try {
      final uri = Uri.parse(
          '$_dataBase/energyComparison/hourly/${Uri.encodeComponent(deviceId)}');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];
      final rows = jsonDecode(res.body);
      if (rows is! List) return [];
      final out = <({int hour, double kwh})>[];
      for (final r in rows) {
        if (r is! Map) continue;
        final t = (r['event_time'] ?? '').toString();
        final hour = int.tryParse(t.split(':').first) ?? -1;
        final kwh = _toDouble(r['today_kWh']);
        if (hour >= 0 && hour <= 23) out.add((hour: hour, kwh: kwh));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Real-time current load (kW) from InfluxDB.
  static Future<double> _fetchCurrentLoadInfluxKw(String deviceId) async {
    if (deviceId.isEmpty) return 0;
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetailsInfluxDb/power-load/current?deviceId=${Uri.encodeComponent(deviceId)}');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 0;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return _toDouble(body['power_kw']);
    } catch (_) {
      return 0;
    }
  }

  /// Latest power factor from MySQL hourly table (via energyDetails/data-logger).
  static Future<double> _fetchLatestPowerFactorMysql(String deviceId) async {
    if (deviceId.isEmpty) return 0;
    try {
      final uri = Uri.parse(
        '$_dataBase/energyDetails/data-logger?device_id=${Uri.encodeQueryComponent(deviceId)}&limit=1&order=desc',
      );
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 0;
      final rows = jsonDecode(res.body);
      if (rows is! List || rows.isEmpty) return 0;
      final first = rows.first;
      if (first is! Map) return 0;
      return _toDouble(first['power_factor']);
    } catch (_) {
      return 0;
    }
  }

  static Future<double> _fetchContractKw(
      String userId, String deviceId, String categoryId) async {
    try {
      if (userId.isNotEmpty) {
        // Billing config is shared across every user of this client, not
        // per-login — see AppConfig.sharedConfigOwnerId.
        final billingUri = categoryId.isNotEmpty
            ? '$_dataBase/masterBillingConfig/${AppConfig.sharedConfigOwnerId}/$categoryId'
            : '$_dataBase/masterBillingConfig/${AppConfig.sharedConfigOwnerId}/active';
        final res = await http
            .get(Uri.parse(billingUri), headers: AppConfig.headers)
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final root = jsonDecode(res.body) as Map<String, dynamic>;
          final cfg = root['config'] as Map<String, dynamic>? ?? root;
          final md = _toDouble(cfg['contractMdKw'] ??
              cfg['contract_md_kW'] ??
              cfg['mdContractKw']);
          if (md > 0) return md;
        }
      }
      final sim = await _fetchTnbSimulator(deviceId);
      final fromSim = _toDouble(sim['contract_md_kW'] ?? sim['contractMdKw']);
      if (fromSim > 0) return fromSim;
    } catch (_) {}
    return 2100;
  }

  /// Latest 30-min MD reading (kW) — Thong Guan Overall_hourly via power-load-24h.
  static Future<double> _fetchLatestKw(String deviceId) async {
    if (deviceId.isEmpty) return 0;
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetails/power-load-24h/${Uri.encodeComponent(deviceId)}');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return 0;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as List?) ?? [];
      if (data.isNotEmpty) {
        final last = data.last as Map<String, dynamic>;
        final kw = _toDouble(last['max_demand_kW']);
        if (kw > 0) return kw;
      }
      final stats = body['statistics'] as Map<String, dynamic>?;
      return _toDouble(
          stats?['current_max_demand_kW'] ?? stats?['max_demand_kW']);
    } catch (_) {
      return 0;
    }
  }

  /// Today + yesterday daily kWh from Overall_daily_energy_consumption.
  static Future<(double today, double yesterday)> _fetchDailyTodayYesterday(
      String deviceId) async {
    if (deviceId.isEmpty) return (0.0, 0.0);
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetails/data/${Uri.encodeComponent(deviceId)}/daily');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return (0.0, 0.0);
      final rows = jsonDecode(res.body) as List<dynamic>;
      if (rows.isEmpty) return (0.0, 0.0);
      final today = _toDouble((rows.last as Map)['value']);
      final yesterday = rows.length > 1
          ? _toDouble((rows[rows.length - 2] as Map)['value'])
          : 0.0;
      return (today, yesterday);
    } catch (_) {
      return (0.0, 0.0);
    }
  }

  /// Raw kW series from Max Demand Monitoring's power-load-24h API (max_demand_kW).
  static Future<List<double>> _fetchPowerLoad24hKw(String deviceId) async {
    final series = await _fetchHourly24hSeries(deviceId);
    return series.mdKw;
  }

  static double _sanitizeChartKw(double kw, {double ceiling = 12000}) {
    if (kw.isNaN || kw.isInfinite || kw < 0) return 0;
    return kw > ceiling ? 0 : kw;
  }

  /// 30-min SQL buckets: power_kW + max_demand_kW + time_label from Overall_hourly_energy_consumption.
  static Future<
          ({List<double> powerKw, List<double> mdKw, List<String> labels})>
      _fetchHourly24hSeries(
    String deviceId,
  ) async {
    if (deviceId.isEmpty)
      return (powerKw: <double>[], mdKw: <double>[], labels: <String>[]);
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetails/power-load-24h/${Uri.encodeComponent(deviceId)}');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200)
        return (powerKw: <double>[], mdKw: <double>[], labels: <String>[]);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as List?) ?? [];
      final powerKw = <double>[];
      final mdKw = <double>[];
      final labels = <String>[];
      for (final row in data) {
        if (row is! Map) continue;
        labels.add(row['time_label']?.toString() ?? '');
        powerKw.add(_sanitizeChartKw(
            _toDouble(row['power_kW'] ?? row['max_demand_kW'])));
        mdKw.add(_sanitizeChartKw(_toDouble(row['max_demand_kW'])));
      }
      return (powerKw: powerKw, mdKw: mdKw, labels: labels);
    } catch (_) {
      return (powerKw: <double>[], mdKw: <double>[], labels: <String>[]);
    }
  }

  /// Monthly-mode: daily interval energy (kWh) + date labels.
  static int _daysInCalendarMonth(DateTime when) =>
      DateTime(when.year, when.month + 1, 0).day;

  /// Map daily-series rows to calendar day (1..N) for the current month.
  static Map<int, double> _dailyKwhByCalendarDay(
      _LabeledSeries series, DateTime when) {
    final requireMonth = when.month;
    final maxDay = _daysInCalendarMonth(when);
    final map = <int, double>{};
    for (var i = 0; i < series.values.length; i++) {
      final label = i < series.labels.length ? series.labels[i].trim() : '';
      var day = 0;
      final slash = RegExp(r'^(\d{1,2})/(\d{1,2})$').firstMatch(label);
      if (slash != null) {
        final month = int.tryParse(slash.group(2)!) ?? 0;
        if (month != requireMonth) continue;
        day = int.tryParse(slash.group(1)!) ?? 0;
      } else if (label.isNotEmpty) {
        final parts = label.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          const months = {
            'jan': 1,
            'feb': 2,
            'mar': 3,
            'apr': 4,
            'may': 5,
            'jun': 6,
            'jul': 7,
            'aug': 8,
            'sep': 9,
            'oct': 10,
            'nov': 11,
            'dec': 12,
          };
          final key = parts.first.toLowerCase();
          final abbr = key.length >= 3 ? key.substring(0, 3) : key;
          final m = months[abbr];
          if (m != null && m != requireMonth) continue;
          day = int.tryParse(parts.last) ?? 0;
        } else {
          day = int.tryParse(
                  RegExp(r'(\d{1,2})').firstMatch(label)?.group(1) ?? '') ??
              0;
        }
      }
      if (day <= 0) day = i + 1;
      if (day < 1 || day > maxDay) continue;
      map[day] = series.values[i];
    }
    return map;
  }

  static ({List<double> grid, List<double> solar, List<String> labels})
      _buildAlignedMonthlyTrend({
    required Map<int, double> gridByDay,
    required Map<int, double> solarByDay,
    required DateTime when,
  }) {
    final days = _daysInCalendarMonth(when);
    final gridVals = <double>[];
    final solarVals = <double>[];
    final labels = <String>[];
    for (var d = 1; d <= days; d++) {
      gridVals.add(gridByDay[d] ?? 0.0);
      solarVals.add(solarByDay[d] ?? 0.0);
      labels.add('$d/${when.month}');
    }
    return (grid: gridVals, solar: solarVals, labels: labels);
  }

  static Future<({List<double> values, List<String> labels})>
      _fetchDailySeriesKwh(String deviceId) async {
    if (deviceId.isEmpty) return (values: <double>[], labels: <String>[]);
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetails/data/${Uri.encodeComponent(deviceId)}/daily');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200)
        return (values: <double>[], labels: <String>[]);
      final rows = jsonDecode(res.body);
      if (rows is! List) return (values: <double>[], labels: <String>[]);
      final values = <double>[];
      final labels = <String>[];
      for (final r in rows) {
        if (r is! Map) continue;
        values.add(_toDouble(r['value']));
        labels.add(r['label']?.toString() ?? '');
      }
      return (values: values, labels: labels);
    } catch (_) {
      return (values: <double>[], labels: <String>[]);
    }
  }

  /// Monthly-mode: daily max demand (kW) + date labels from Overall_daily_energy_consumption.
  static Future<({List<double> values, List<String> labels})>
      _fetchDailyMaxDemandThisMonthKw(String deviceId) async {
    if (deviceId.isEmpty) return (values: <double>[], labels: <String>[]);
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetails/max-demand-chart?device_id=${Uri.encodeQueryComponent(deviceId)}');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200)
        return (values: <double>[], labels: <String>[]);
      final rows = jsonDecode(res.body);
      if (rows is! List) return (values: <double>[], labels: <String>[]);
      final values = <double>[];
      final labels = <String>[];
      for (final r in rows) {
        if (r is! Map) continue;
        values.add(_toDouble(r['value']));
        labels.add(r['label']?.toString() ?? '');
      }
      return (values: values, labels: labels);
    } catch (_) {
      return (values: <double>[], labels: <String>[]);
    }
  }

  static List<double> _normalizeSeries(List<double> values) {
    if (values.isEmpty) return [];
    final max = values.reduce((a, b) => a > b ? a : b);
    if (max <= 0) return values;
    return values.map((v) => v / max).toList();
  }

  static List<double> _mdProfileTodayKw(
      List<double> kwSeries, double contractKw) {
    if (kwSeries.isEmpty || contractKw <= 0) return [];
    var runMax = 0.0;
    return kwSeries.map((kw) {
      if (kw > runMax) runMax = kw;
      return runMax / contractKw;
    }).toList();
  }

  /// Running cumulative max kW (today's MD profile).
  static double _latestMdKw(_Hourly24hSeries series) {
    for (var i = series.mdKw.length - 1; i >= 0; i--) {
      final v = series.mdKw[i];
      if (v > 0) return v;
    }
    return 0;
  }

  static (double today, double yesterday) _lastTwoDaily(_LabeledSeries series) {
    final values = series.values;
    if (values.isEmpty) return (0.0, 0.0);
    final today = values.last;
    final yesterday = values.length > 1 ? values[values.length - 2] : 0.0;
    return (today, yesterday);
  }

  static double _kwFromHourlyOrMonthly(
      _Hourly24hSeries hourly, double monthlyKwh) {
    final kw = _latestMdKw(hourly);
    if (kw > 0) return kw;
    return monthlyKwh > 0 ? monthlyKwh / (30 * 24) : 0.0;
  }

  static List<double> _cumulativeMaxKw(List<double> kwSeries) {
    if (kwSeries.isEmpty) return [];
    var runMax = 0.0;
    return kwSeries.map((kw) {
      if (kw > runMax) runMax = kw;
      return runMax;
    }).toList();
  }

  /// Hourly solar kW (kWh per hour bucket) + hour labels.
  static Future<({List<double> values, List<String> labels})>
      _fetchHourlySolarSeries(String deviceId) async {
    if (deviceId.isEmpty) return (values: <double>[], labels: <String>[]);
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetails/data/${Uri.encodeComponent(deviceId)}/hourly');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200)
        return (values: <double>[], labels: <String>[]);
      final rows = jsonDecode(res.body) as List<dynamic>;
      final slots = List<double>.filled(24, 0);
      final labels = List<String>.generate(
          24, (h) => '${h.toString().padLeft(2, '0')}:00');
      for (final row in rows) {
        if (row is! Map) continue;
        final h = int.tryParse(row['label']?.toString() ?? '') ?? -1;
        if (h >= 0 && h < 24) slots[h] = _toDouble(row['value']);
      }

      // Fallback to MySQL energyComparison if InfluxDB returned flat 0s (e.g. for VSOLAR)
      if (!slots.any((v) => v > 0)) {
        final mysqlData = await _fetchHourlyKwhToday(deviceId);
        for (final d in mysqlData) {
          if (d.hour >= 0 && d.hour < 24) slots[d.hour] = d.kwh;
        }
      }

      return (values: slots, labels: labels);
    } catch (_) {
      return (values: <double>[], labels: <String>[]);
    }
  }

  /// Hourly solar kW (kWh per hour bucket).
  static Future<List<double>> _fetchHourlySolarKw(String deviceId) async {
    final series = await _fetchHourlySolarSeries(deviceId);
    return series.values;
  }

  /// Daily max demand this month (max-demand-chart) — fallback when 24h is sparse.
  static Future<List<double>> _fetchMaxDemandChartNorm(
      String deviceId, double contractKw) async {
    if (deviceId.isEmpty || contractKw <= 0) return [];
    try {
      final uri = Uri.parse(
        '$_dataBase/energyDetails/max-demand-chart?device_id=${Uri.encodeComponent(deviceId)}',
      );
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];
      final rows = jsonDecode(res.body) as List<dynamic>;
      final values = <double>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final v = _toDouble(row['value']);
        if (v > 0) values.add(v / contractKw);
      }
      return values;
    } catch (_) {
      return [];
    }
  }

  /// 24h load curve (normalized 0–1) from power-load-24h.
  static Future<List<double>> _fetchLoadProfile24h(String deviceId) async {
    final raw = await _fetchPowerLoad24hKw(deviceId);
    return _normalizeSeries(raw);
  }

  /// Hourly kWh today (normalized) — fallback when power-load is empty.
  static Future<List<double>> _fetchHourlyKwhProfile(String deviceId) async {
    if (deviceId.isEmpty) return [];
    try {
      final uri = Uri.parse(
          '$_dataBase/energyDetails/data/${Uri.encodeComponent(deviceId)}/hourly');
      final res = await http
          .get(uri, headers: AppConfig.headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];
      final rows = jsonDecode(res.body) as List<dynamic>;
      final slots = List<double>.filled(24, 0);
      for (final row in rows) {
        if (row is! Map) continue;
        final h = int.tryParse(row['label']?.toString() ?? '') ?? -1;
        if (h >= 0 && h < 24) slots[h] = _toDouble(row['value']);
      }
      final max = slots.reduce((a, b) => a > b ? a : b);
      if (max <= 0) return slots;
      return slots.map((v) => v / max).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<double>> _fetchHourlyProfile(String deviceId) async {
    final load = await _fetchLoadProfile24h(deviceId);
    if (load.length >= 4) return load;
    return _fetchHourlyKwhProfile(deviceId);
  }

  static final Map<String, (DateTime, _Hourly24hSeries)> _hourlySeriesCache =
      {};

  static Future<_Hourly24hSeries> _fetchHourly24hSeriesCached(
      String deviceId) async {
    final hit = _hourlySeriesCache[deviceId];
    if (hit != null &&
        DateTime.now().difference(hit.$1) < const Duration(seconds: 45)) {
      return hit.$2;
    }
    final series = await _fetchHourly24hSeries(deviceId);
    _hourlySeriesCache[deviceId] = (DateTime.now(), series);
    return series;
  }

  static bool _isDailyEnergyField(String field) {
    final f = field.toLowerCase();
    return f.contains('daily') ||
        f.contains('total energy') ||
        f.contains('generation');
  }

  static double _heroTodayEnergyKwh({
    required double dailyKwh,
    required double billUsageKwh,
  }) {
    if (dailyKwh > 0) return dailyKwh;
    return billUsageKwh > 0 ? billUsageKwh : 0;
  }

  static double _heroTodayCarbonT({
    required double dailyCarbonKg,
    required double energyKwh,
    required double emissionFactor,
  }) {
    if (dailyCarbonKg > 0) return dailyCarbonKg / 1000.0;
    if (energyKwh > 0 && emissionFactor > 0)
      return (energyKwh * emissionFactor) / 1000.0;
    return 0;
  }

  /// The meters a mapping names. Block card rows can carry several, comma
  /// separated, because a block's grid import or solar is usually split across
  /// more than one meter; every other mapping is a single id and comes back as
  /// a one-element list.
  static List<String> _mappedDevices(_PeccMapping map) => map.device
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  static double _dailyMappedKwh(
    Map<String, _PeccMapping> mappings,
    Map<String, _DeviceEnergy> energyCache,
    String key,
  ) {
    final map = _m(mappings, key);
    if (map == null || !map.isMapped) return 0;
    var sum = 0.0;
    for (final id in _mappedDevices(map)) {
      sum += energyCache[id]?.dailyKwh ?? 0;
    }
    return sum;
  }

  static double _monthlyMappedKwh(
    Map<String, _PeccMapping> mappings,
    Map<String, _DeviceEnergy> energyCache,
    String key,
  ) {
    final map = _m(mappings, key);
    if (map == null || !map.isMapped) return 0;
    var sum = 0.0;
    for (final id in _mappedDevices(map)) {
      sum += energyCache[id]?.monthlyKwh ?? 0;
    }
    return sum;
  }

  /// GRID (TNB) card kWh — direct device mapping (`tnb.kwh`), else hero grid split.
  static double _tnbKwhToday(
    Map<String, _PeccMapping> mappings,
    Map<String, _DeviceEnergy> energyCache, {
    required double gridFallback,
  }) {
    final mapped = _dailyMappedKwh(mappings, energyCache, 'tnb.kwh');
    return mapped > 0 ? mapped : gridFallback;
  }

  static double _tnbKwhMonthly(
    Map<String, _PeccMapping> mappings,
    Map<String, _DeviceEnergy> energyCache, {
    required double gridFallback,
  }) {
    final mapped = _monthlyMappedKwh(mappings, energyCache, 'tnb.kwh');
    return mapped > 0 ? mapped : gridFallback;
  }

  /// Lot 237: hero[0] is the Grid Import meter (e.g. VDPM002).
  /// Total Consumption = Grid + Solar. Never invent Total = Solar alone.
  static ({double total, double grid, double solar}) _pfSplitTotals({
    required double hero0,
    required double solar,
  }) {
    final grid = hero0 > 0 ? hero0 : 0.0;
    final sol = solar > 0 ? solar : 0.0;
    if (grid > 0 && sol > 0) {
      return (total: grid + sol, grid: grid, solar: sol);
    }
    if (grid > 0) return (total: grid, grid: grid, solar: 0);
    // Solar-only: keep generation visible, but do not fake total consumption / 100% mix.
    if (sol > 0) return (total: 0, grid: 0, solar: sol);
    return (total: 0, grid: 0, solar: 0);
  }

  static String _pctOf(double part, double whole) {
    if (whole <= 0 || part < 0) return '—';
    return '${(part / whole * 100).toStringAsFixed(1)}%';
  }

  static List<double> _hourlyBucketsTo24(
      List<({int hour, double kwh})> buckets) {
    final out = List<double>.filled(24, 0);
    for (final b in buckets) {
      if (b.hour >= 0 && b.hour < 24) out[b.hour] += b.kwh;
    }
    return out;
  }

  static PeccPowerFlowBlock _pfBlockFromParts({
    required String label,
    required double total,
    required double grid,
    required double solar,
  }) {
    var t = total;
    var g = grid;
    var s = solar;
    if (t <= 0 && (g > 0 || s > 0)) t = g + s;
    if (g <= 0 && t > 0) g = (t - s).clamp(0.0, t);
    if (s <= 0 && t > 0) s = (t - g).clamp(0.0, t);
    return PeccPowerFlowBlock(
      label: label,
      totalKwh: t > 0 ? _formatKwhRaw(t) : '—',
      gridKwh: g > 0 ? _formatKwhRaw(g) : '—',
      gridPct: _pctOf(g, t),
      solarKwh: s > 0 ? _formatKwhRaw(s) : '—',
      solarPct: _pctOf(s, t),
      totalRaw: t,
    );
  }

  static List<String> _buildPfInsights({
    required double total,
    required double solar,
    required double costToday,
    required double costYesterday,
    required List<PeccPowerFlowBlock> blocks,
    String costCompareLabel = 'yesterday',
  }) {
    final out = <String>[];
    // INS-01
    if (total >= 500 && total > 0) {
      final pct = (solar / total * 100).toStringAsFixed(1);
      out.add('Solar is covering $pct% of total consumption.');
    }
    // INS-02
    if (total >= 500 && blocks.any((b) => b.totalRaw > 0)) {
      final ranked = [...blocks]..sort((a, b) {
          final c = b.totalRaw.compareTo(a.totalRaw);
          if (c != 0) return c;
          return a.label.compareTo(b.label);
        });
      final top = ranked.first;
      final pct = (top.totalRaw / total * 100).toStringAsFixed(1);
      out.add('${top.label} has the highest energy consumption ($pct%).');
    }
    // INS-03 (most grid-dependent block) is intentionally not emitted.
    // The rule spec marks it BLOCKED: it is only valid when per-block solar is
    // genuinely metered. If plant solar is allocated proportionally instead,
    // grid_dependency_% works out identical for every block and the ranking is
    // meaningless. Removed until the electrical team confirms whether the solar
    // plant is wired to each Block/Sub-DB or only to the Plant Total.
    // INS-04
    if (costYesterday > 0 && costToday > 0) {
      final change = (costToday / costYesterday - 1) * 100;
      if (change.abs() >= 15) {
        final word = change >= 0 ? 'increased' : 'decreased';
        out.add(
            'Energy cost $word by ${change.abs().toStringAsFixed(1)}% compared to $costCompareLabel.');
      }
    }
    return out;
  }

  /// Instant Lot 237 paint from energy totals only (no hourly SQL wait).
  static PeccLiveData _lot237Partial({
    required Map<String, _PeccMapping> mappings,
    required Map<String, _DeviceEnergy> energyCache,
    required Map<String, _TnbBill> billCache,
    required String billingDevice,
  }) {
    final heroEnergyMap = _m(mappings, 'hero[0]') ?? _m(mappings, 'glance[0]');
    final heroSolarMap = _m(mappings, 'hero[1]');
    final mainDevice = heroEnergyMap?.device ?? billingDevice;
    final heroDevice = heroEnergyMap != null && heroEnergyMap.isMapped
        ? heroEnergyMap.device
        : mainDevice;
    final dailyKwh =
        heroDevice.isNotEmpty ? energyCache[heroDevice]?.dailyKwh ?? 0 : 0.0;
    final dailyCarbonKg = heroDevice.isNotEmpty
        ? energyCache[heroDevice]?.dailyCarbonKg ?? 0
        : 0.0;
    final solarDaily = heroSolarMap != null && heroSolarMap.isMapped
        ? energyCache[heroSolarMap.device]?.dailyKwh ?? 0
        : 0.0;
    final heroBill = mainDevice.isNotEmpty
        ? billCache[mainDevice] ?? _TnbBill()
        : _TnbBill();
    final heroEnergyKwh = _heroTodayEnergyKwh(
        dailyKwh: dailyKwh, billUsageKwh: heroBill.totalUsageKwh);
    final split = _pfSplitTotals(hero0: heroEnergyKwh, solar: solarDaily);
    // The bill endpoints report nothing for this tenant — the simulator returns
    // no total_bill or total_usage_kWh, and bill-total is zero for every month —
    // so estimateDailyCost divides by nothing and Energy Cost read as a dash on
    // Daily while Monthly showed a figure. Monthly only worked because the
    // group path already falls back to a flat rate; applying the same fallback
    // here stops the two periods disagreeing.
    final billedKwh = split.grid > 0 ? split.grid : heroEnergyKwh;
    final estimatedFromBill = heroBill.estimateDailyCost(billedKwh);
    final dailyCost = estimatedFromBill > 0
        ? estimatedFromBill
        : billedKwh * _fallbackTariffRmPerKwh;
    final carbonT = _heroTodayCarbonT(
      dailyCarbonKg: dailyCarbonKg,
      energyKwh: split.grid > 0 ? split.grid : heroEnergyKwh,
      emissionFactor: _cachedEmissionFactor ?? 0.525,
    );

    final pfBlocks = <PeccPowerFlowBlock>[];
    for (final e in [('A', 'blockA'), ('B', 'blockB'), ('C', 'blockC')]) {
      pfBlocks.add(_pfBlockFromParts(
        label: 'BLOCK ${e.$1}',
        total: _dailyMappedKwh(mappings, energyCache, '${e.$2}.total'),
        grid: _dailyMappedKwh(mappings, energyCache, '${e.$2}.gridImport'),
        solar: _dailyMappedKwh(mappings, energyCache, '${e.$2}.solar'),
      ));
    }

    // Monthly (MTD) from same energy cache so Daily/Monthly toggle works before charts finish.
    final heroMonthlyRaw =
        heroDevice.isNotEmpty ? energyCache[heroDevice]?.monthlyKwh ?? 0 : 0.0;
    final solarMonthlyRaw = heroSolarMap != null && heroSolarMap.isMapped
        ? energyCache[heroSolarMap.device]?.monthlyKwh ?? 0
        : 0.0;
    final pfSplitMonthly =
        _pfSplitTotals(hero0: heroMonthlyRaw, solar: solarMonthlyRaw);
    // Same reasoning as the daily cost above: with no bill to read, an estimate
    // from the energy actually measured beats an empty card.
    final monthlyCost = heroBill.totalBill > 0
        ? heroBill.totalBill
        : (pfSplitMonthly.grid > 0
            ? pfSplitMonthly.grid * _fallbackTariffRmPerKwh
            : 0.0);
    final emissionFactor = _cachedEmissionFactor ?? 0.525;
    final carbonMonthlyT = pfSplitMonthly.grid > 0 && emissionFactor > 0
        ? (pfSplitMonthly.grid * emissionFactor) / 1000.0
        : 0.0;
    final pfBlocksMonthly = <PeccPowerFlowBlock>[
      for (final e in [('A', 'blockA'), ('B', 'blockB'), ('C', 'blockC')])
        _pfBlockFromParts(
          label: 'BLOCK ${e.$1}',
          total: _monthlyMappedKwh(mappings, energyCache, '${e.$2}.total'),
          grid: _monthlyMappedKwh(mappings, energyCache, '${e.$2}.gridImport'),
          solar: _monthlyMappedKwh(mappings, energyCache, '${e.$2}.solar'),
        ),
    ];
    final pfInsightsMonthly = _buildPfInsights(
      total: pfSplitMonthly.total,
      solar: pfSplitMonthly.solar,
      costToday: monthlyCost,
      costYesterday: 0,
      blocks: pfBlocksMonthly,
      costCompareLabel: 'last month',
    );

    final flowValues = <String, String>{};
    double blocksSum = 0;
    const flowKeys = [
      'flow.blockA',
      'flow.blockB',
      'flow.blockC',
      'flow.solar',
      'flow.plantTotal'
    ];
    for (final key in flowKeys) {
      final map = _m(mappings, key);
      if (map == null || !map.isMapped) continue;
      final d = energyCache[map.device]?.dailyKwh ?? 0;
      if (d <= 0) continue;
      if (key != 'flow.plantTotal') blocksSum += d;
    }

    final now = DateTime.now();
    final lastUpdated =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final hasData = split.total > 0 ||
        solarDaily > 0 ||
        heroBill.totalBill > 0 ||
        blocksSum > 0;
    final tnbKwhToday =
        _tnbKwhToday(mappings, energyCache, gridFallback: split.grid);
    final tnbKwhMonthly = _tnbKwhMonthly(mappings, energyCache,
        gridFallback: pfSplitMonthly.grid);

    return PeccLiveData(
      heroTotalEnergyToday:
          split.total > 0 ? '${_formatKwhRaw(split.total)} kWh' : '—',
      heroSolarToday:
          split.solar > 0 ? '${_formatKwhRaw(split.solar)} kWh' : '—',
      heroGridImportToday:
          split.grid > 0 ? '${_formatKwhRaw(split.grid)} kWh' : '—',
      heroEnergyCostToday: dailyCost > 0
          ? 'RM ${_addThousands(dailyCost.toStringAsFixed(2))}'
          : '—',
      heroCarbonToday:
          carbonT > 0 ? '${carbonT.toStringAsFixed(1)} tCO₂e' : '—',
      energyToday: _formatKwh(split.total),
      energyCostToday: _formatRm(dailyCost),
      sidebarPlantHealth: hasData ? 'Healthy' : '—',
      sidebarPlantHealthSub: hasData ? '—' : 'Awaiting mapped data',
      totalCostMtd: _formatRm(heroBill.totalBill),
      totalEnergyMtd: _formatEnergy(energyCache[mainDevice]?.monthlyKwh ?? 0),
      lastUpdated: lastUpdated,
      hasData: hasData,
      pfPlantTotalKwh: split.total > 0 ? _formatKwhRaw(split.total) : '—',
      pfPlantSolarKwh: split.solar > 0 ? _formatKwhRaw(split.solar) : '—',
      pfPlantSolarPct: _pctOf(split.solar, split.total),
      pfPlantGridKwh: split.grid > 0 ? _formatKwhRaw(split.grid) : '—',
      pfPlantGridPct: _pctOf(split.grid, split.total),
      pfTnbKwh: tnbKwhToday > 0 ? _formatKwhRaw(tnbKwhToday) : '—',
      pfBlocks: pfBlocks.any((b) => b.totalRaw > 0) ? pfBlocks : const [],
      pfPlantTotalKwhMonthly:
          pfSplitMonthly.total > 0 ? _formatKwhRaw(pfSplitMonthly.total) : '—',
      pfPlantSolarKwhMonthly:
          pfSplitMonthly.solar > 0 ? _formatKwhRaw(pfSplitMonthly.solar) : '—',
      pfPlantSolarPctMonthly:
          _pctOf(pfSplitMonthly.solar, pfSplitMonthly.total),
      pfPlantGridKwhMonthly:
          pfSplitMonthly.grid > 0 ? _formatKwhRaw(pfSplitMonthly.grid) : '—',
      pfPlantGridPctMonthly: _pctOf(pfSplitMonthly.grid, pfSplitMonthly.total),
      pfTnbKwhMonthly: tnbKwhMonthly > 0 ? _formatKwhRaw(tnbKwhMonthly) : '—',
      pfHeroCostMonthly: monthlyCost > 0
          ? 'RM ${_addThousands(monthlyCost.toStringAsFixed(2))}'
          : '—',
      pfHeroCarbonMonthly: carbonMonthlyT > 0
          ? '${carbonMonthlyT.toStringAsFixed(1)} tCO₂e'
          : '—',
      pfBlocksMonthly: pfBlocksMonthly.any((b) => b.totalRaw > 0)
          ? pfBlocksMonthly
          : const [],
      pfInsightsMonthly: pfInsightsMonthly,
    );
  }

  /// The standard flexi dashboard resolver — hero[0..3], sidebar, flow.*
  /// keys. Named for Lot 237, the plant it was built against, but reused for
  /// every plant that isn't Lot 48 or a Lot 237 block (see isFlexiPlant in
  /// [resolve]).
  static Future<PeccLiveData> _resolveLot237({
    required Map<String, _PeccMapping> mappings,
    required String userId,
    required Map<String, _DeviceEnergy> energyCache,
    required Map<String, _TnbBill> billCache,
    required String billingDevice,
    required Map<String, String> deviceCategories,
    bool includeCharts = true,
    void Function(PeccLiveData data)? onProgress,
    // Only Lot 237's real solar device is literally named 'VSOLAR'; every
    // other plant with no hero[1]/flow.solar mapped should read as
    // unmapped, not silently read Lot 237's device.
    String defaultSolarDevice = '',
  }) async {
    final cache = _PeccRequestCache();
    final heroEnergyMap = _m(mappings, 'hero[0]') ?? _m(mappings, 'glance[0]');
    final heroSolarMap = _m(mappings, 'hero[1]');
    final solarDevice = heroSolarMap != null && heroSolarMap.isMapped
        ? heroSolarMap.device
        : defaultSolarDevice;
    final mainDevice = heroEnergyMap?.device ?? billingDevice;
    final mainCategory = deviceCategories[mainDevice] ?? '';

    final heroEnergyDevice = heroEnergyMap != null && heroEnergyMap.isMapped
        ? heroEnergyMap.device
        : mainDevice;
    final heroEnergyField = heroEnergyMap?.field?.toLowerCase() ?? '';
    final heroEnergyIsDaily = _isDailyEnergyField(heroEnergyField);

    final loadChartDevice =
        _m(mappings, 'chart.loadProfile')?.device ?? mainDevice;
    final mdChartDevice =
        _m(mappings, 'chart.mdProfile.actual')?.device ?? loadChartDevice;
    final solarChartDevice = _m(mappings, 'chart.solar')?.device ?? solarDevice;

    final sidebarLoadMap = _m(mappings, 'sidebar[1]');
    final sidebarSolarMap = _m(mappings, 'sidebar[4]');
    final loadDevice = sidebarLoadMap != null && sidebarLoadMap.isMapped
        ? sidebarLoadMap.device
        : mainDevice;
    // Monthly MD always from plant TNB meter — same source as kanban Monthly Max Demand card.
    final mdBillingDevice =
        billingDevice.isNotEmpty ? billingDevice : mainDevice;

    const flowKeys = [
      'flow.blockA',
      'flow.blockB',
      'flow.blockC',
      'flow.solar',
      'flow.plantTotal'
    ];
    final hourlyDevices = <String>{};
    final dailyDevices = <String>{};
    for (final key in flowKeys) {
      final map = _m(mappings, key);
      if (map == null || !map.isMapped) continue;
      hourlyDevices.add(map.device);
    }
    if (mainDevice.isNotEmpty) hourlyDevices.add(mainDevice);
    if (loadDevice.isNotEmpty) hourlyDevices.add(loadDevice);
    if (mdBillingDevice.isNotEmpty) hourlyDevices.add(mdBillingDevice);
    if (loadChartDevice.isNotEmpty) hourlyDevices.add(loadChartDevice);
    if (mdChartDevice.isNotEmpty) hourlyDevices.add(mdChartDevice);
    if (loadChartDevice.isNotEmpty) dailyDevices.add(loadChartDevice);
    if (solarChartDevice.isNotEmpty) {
      dailyDevices.add(solarChartDevice);
      hourlyDevices.add(solarChartDevice);
    }
    if (heroEnergyIsDaily && heroEnergyDevice.isNotEmpty)
      dailyDevices.add(heroEnergyDevice);
    if (solarDevice.isNotEmpty) dailyDevices.add(solarDevice);
    final trendTotalPrefetch = _m(mappings, 'trend.total')?.isMapped == true
        ? _m(mappings, 'trend.total')!.device
        : heroEnergyDevice;
    final trendSolarPrefetch = _m(mappings, 'trend.solar')?.isMapped == true
        ? _m(mappings, 'trend.solar')!.device
        : solarDevice;
    if (trendTotalPrefetch.isNotEmpty) dailyDevices.add(trendTotalPrefetch);
    if (trendSolarPrefetch.isNotEmpty) dailyDevices.add(trendSolarPrefetch);

    // Single prefetch barrier — hero/flow (SQL hourly) and chart/extras
    // requests are independent, so firing them together instead of two
    // sequential waves halves the cold-load latency of the Lot 237 view.
    await cache.prefetchAll([
      if (mainDevice.isNotEmpty) cache.tnbSimulator(mainDevice).then((_) {}),
      if (includeCharts)
        ...hourlyDevices.map((d) => cache.hourly24h(d).then((_) {})),
      _fetchActiveEmissionFactor().then((_) {}),
      if (includeCharts) ...[
        if (mainDevice.isNotEmpty)
          cache.contractKw(userId, mainDevice, mainCategory).then((_) {}),
        if (heroEnergyDevice.isNotEmpty)
          cache.hourlyKwhToday(heroEnergyDevice).then((_) {}),
        if (heroEnergyDevice.isNotEmpty)
          cache.powerFactor(heroEnergyDevice).then((_) {}),
        ...dailyDevices.map((d) => cache.dailySeries(d).then((_) {})),
        if (mdChartDevice.isNotEmpty)
          cache.dailyMaxDemand(mdChartDevice).then((_) {}),
        if (solarChartDevice.isNotEmpty)
          cache.hourlySolar(solarChartDevice).then((_) {}),
        if (mdBillingDevice.isNotEmpty)
          _fetchLastMonthMaxDemandKw(mdBillingDevice).then((_) {}),
      ],
    ]);

    final heroBill = mainDevice.isNotEmpty
        ? billCache[mainDevice] ??
            await _fetchTnbBill(userId, mainDevice, categoryId: mainCategory)
        : _TnbBill();
    final tnbSim = mainDevice.isNotEmpty
        ? await cache.tnbSimulator(mainDevice)
        : <String, dynamic>{};
    final mdSim = mdBillingDevice.isNotEmpty
        ? await cache.tnbSimulator(mdBillingDevice)
        : <String, dynamic>{};
    // tnb-bill-simulator max_demand_kW — identical to Max Demand Monitoring / kanban card.
    final mdKw = _toDouble(mdSim['max_demand_kW']);
    final contractKwRaw = mdBillingDevice.isNotEmpty && includeCharts
        ? await cache.contractKw(userId, mdBillingDevice,
            deviceCategories[mdBillingDevice] ?? mainCategory)
        : (mainDevice.isNotEmpty && includeCharts
            ? await cache.contractKw(userId, mainDevice, mainCategory)
            : 2100.0);
    final contractKw = contractKwRaw;
    final contractMw = contractKw / 1000;
    final pfValue =
        _toDouble(tnbSim['power_factor'] ?? tnbSim['power_factor_avg'])
            .clamp(0.0, 1.0);

    final dailyKwh = heroEnergyDevice.isNotEmpty
        ? energyCache[heroEnergyDevice]?.dailyKwh ?? 0
        : 0.0;
    final dailyCarbonKg = heroEnergyDevice.isNotEmpty
        ? energyCache[heroEnergyDevice]?.dailyCarbonKg ?? 0
        : 0.0;
    final heroEnergyKwh = _heroTodayEnergyKwh(
      dailyKwh: dailyKwh,
      billUsageKwh: heroBill.totalUsageKwh,
    );
    final solarDaily = energyCache[solarDevice]?.dailyKwh ?? 0.0;

    final heroEnergyDaily =
        includeCharts && heroEnergyIsDaily && heroEnergyDevice.isNotEmpty
            ? await cache.dailySeries(heroEnergyDevice)
            : _PeccRequestCache._emptyLabeled;
    final solarDailySeriesForDelta = includeCharts && solarDevice.isNotEmpty
        ? await cache.dailySeries(solarDevice)
        : _PeccRequestCache._emptyLabeled;
    final (_, yesterdayKwh) = _lastTwoDaily(heroEnergyDaily);
    final (_, yesterdaySolarKwh) = _lastTwoDaily(solarDailySeriesForDelta);
    final yesterdayCost = yesterdayKwh > 0
        ? (billCache[mainDevice] ?? heroBill).estimateDailyCost(yesterdayKwh)
        : 0.0;

    final hourlyBuckets = includeCharts && heroEnergyDevice.isNotEmpty
        ? await cache.hourlyKwhToday(heroEnergyDevice)
        : <({int hour, double kwh})>[];
    var peakKwh = 0.0;
    var offPeakKwh = 0.0;
    for (final b in hourlyBuckets) {
      if (b.hour >= 14 && b.hour < 22) {
        peakKwh += b.kwh;
      } else {
        offPeakKwh += b.kwh;
      }
    }
    final energyCostToday = peakKwh * 0.310 + offPeakKwh * 0.272;
    // Fallback: when the daily-total endpoint has no row for this device
    // (common for VDPM002), use today's summed hourly kWh — the charts
    // already have it — so TOTAL ENERGY / CARBON never stay blank.
    final todayHourlyKwh = peakKwh + offPeakKwh;
    final heroEnergyKwhEff = heroEnergyKwh > 0 ? heroEnergyKwh : todayHourlyKwh;
    final pfSplit = _pfSplitTotals(hero0: heroEnergyKwhEff, solar: solarDaily);
    final emissionFactor = await _fetchActiveEmissionFactor();
    final carbonT = _heroTodayCarbonT(
      dailyCarbonKg: dailyCarbonKg,
      energyKwh: pfSplit.grid > 0 ? pfSplit.grid : heroEnergyKwhEff,
      emissionFactor: emissionFactor,
    );
    final dailyCost = includeCharts && (peakKwh + offPeakKwh) > 0
        ? energyCostToday
        : heroBill.estimateDailyCost(
            pfSplit.grid > 0 ? pfSplit.grid : heroEnergyKwhEff);

    final ySplit =
        _pfSplitTotals(hero0: yesterdayKwh, solar: yesterdaySolarKwh);

    // Energy Flow hero deltas stay 4 (total / solar / cost / carbon).
    final heroDeltas = [
      _heroDelta(pfSplit.total, ySplit.total > 0 ? ySplit.total : yesterdayKwh),
      _heroDelta(pfSplit.solar, yesterdaySolarKwh),
      _heroDelta(dailyCost, yesterdayCost, lowerIsBetter: true),
      _heroDelta(
        carbonT,
        ySplit.grid > 0 && emissionFactor > 0
            ? (ySplit.grid * emissionFactor) / 1000.0
            : 0,
        lowerIsBetter: true,
      ),
    ];

    // Power Flow 5 heroes: total / solar / grid / cost / carbon.
    final powerFlowHeroDeltas = [
      _heroDelta(pfSplit.total, ySplit.total > 0 ? ySplit.total : yesterdayKwh),
      _heroDelta(pfSplit.solar, yesterdaySolarKwh),
      _heroDelta(pfSplit.grid, ySplit.grid),
      _heroDelta(dailyCost, yesterdayCost, lowerIsBetter: true),
      _heroDelta(
        carbonT,
        ySplit.grid > 0 && emissionFactor > 0
            ? (ySplit.grid * emissionFactor) / 1000.0
            : 0,
        lowerIsBetter: true,
      ),
    ];

    final pfBlocks = <PeccPowerFlowBlock>[
      for (final e in [('A', 'blockA'), ('B', 'blockB'), ('C', 'blockC')])
        _pfBlockFromParts(
          label: 'BLOCK ${e.$1}',
          total: _dailyMappedKwh(mappings, energyCache, '${e.$2}.total'),
          grid: _dailyMappedKwh(mappings, energyCache, '${e.$2}.gridImport'),
          solar: _dailyMappedKwh(mappings, energyCache, '${e.$2}.solar'),
        ),
    ];
    final pfInsights = _buildPfInsights(
      total: pfSplit.total,
      solar: pfSplit.solar,
      costToday: dailyCost,
      costYesterday: yesterdayCost,
      blocks: pfBlocks,
    );
    final pfBlockBars = (() {
      final live = pfBlocks.where((b) => b.totalRaw > 0).toList()
        ..sort((a, b) {
          final c = b.totalRaw.compareTo(a.totalRaw);
          return c != 0 ? c : a.label.compareTo(b.label);
        });
      if (live.isEmpty) return <PeccBlockRow>[];
      final plant = pfSplit.total > 0
          ? pfSplit.total
          : live.fold<double>(0, (s, b) => s + b.totalRaw);
      return [
        for (final b in live)
          PeccBlockRow(
            label: b.label.replaceFirst('BLOCK ', 'Block '),
            kwhDisplay: '${b.totalKwh} kWh',
            fraction: plant > 0 ? b.totalRaw / plant : 0,
          ),
      ];
    })();

    // Trends: Grid + Solar from mapped devices; Total = Grid + Solar (per hour).
    // Prefer trend.grid; fall back to legacy trend.total / hero[0] (VDPM002 was often
    // saved on trend.total before Total became calculated).
    final trendGridMap = _m(mappings, 'trend.grid');
    final trendTotalLegacyMap = _m(mappings, 'trend.total');
    final trendSolarMap = _m(mappings, 'trend.solar');
    final trendGridDevice = trendGridMap != null && trendGridMap.isMapped
        ? trendGridMap.device
        : (trendTotalLegacyMap != null && trendTotalLegacyMap.isMapped
            ? trendTotalLegacyMap.device
            : heroEnergyDevice);
    final trendSolarDevice = trendSolarMap != null && trendSolarMap.isMapped
        ? trendSolarMap.device
        : solarDevice;
    final trendGridBuckets = includeCharts && trendGridDevice.isNotEmpty
        ? await cache.hourlyKwhToday(trendGridDevice)
        : <({int hour, double kwh})>[];
    final trendSolarBuckets = includeCharts && trendSolarDevice.isNotEmpty
        ? await cache.hourlyKwhToday(trendSolarDevice)
        : <({int hour, double kwh})>[];
    final pfTrendGrid = _hourlyBucketsTo24(trendGridBuckets);
    final pfTrendSolar = _hourlyBucketsTo24(trendSolarBuckets);
    final pfTrendTotal = List.generate(24, (i) {
      final g = i < pfTrendGrid.length ? pfTrendGrid[i] : 0.0;
      final s = i < pfTrendSolar.length ? pfTrendSolar[i] : 0.0;
      return g + s;
    });

    // TNB frequency / PF from mapped devices (fallback simulator PF).
    final tnbPfMap = _m(mappings, 'tnb.pf');
    final tnbFreqMap = _m(mappings, 'tnb.freq');
    final tnbPfDevice = tnbPfMap != null && tnbPfMap.isMapped
        ? tnbPfMap.device
        : (billingDevice.isNotEmpty ? billingDevice : mainDevice);
    final tnbFreqDevice = tnbFreqMap != null && tnbFreqMap.isMapped
        ? tnbFreqMap.device
        : tnbPfDevice;
    if (tnbPfDevice.isNotEmpty && includeCharts)
      await cache.powerFactor(tnbPfDevice);
    if (tnbFreqDevice.isNotEmpty && includeCharts)
      await cache.tnbSimulator(tnbFreqDevice);
    final tnbPfVal = includeCharts && tnbPfDevice.isNotEmpty
        ? await cache.powerFactor(tnbPfDevice)
        : pfValue;
    final tnbSimExtra = includeCharts && tnbFreqDevice.isNotEmpty
        ? await cache.tnbSimulator(tnbFreqDevice)
        : <String, dynamic>{};
    final tnbHzVal = _toDouble(tnbSimExtra['frequency_hz'] ??
        tnbSimExtra['frequency'] ??
        tnbSimExtra['freq_hz']);

    final flowValues = <String, String>{};
    final flowKw = <String, double>{};
    double blocksSumKw = 0;
    for (final key in flowKeys) {
      final map = _m(mappings, key);
      if (map == null || !map.isMapped) continue;
      if (!includeCharts) {
        final kwh = energyCache[map.device]?.dailyKwh ?? 0;
        if (kwh <= 0) continue;
        final shortKey = key.split('.').last;
        flowKw[shortKey] = kwh / 24;
        flowValues[shortKey] = _formatMwFromKw(flowKw[shortKey]!);
        if (shortKey == 'blockA' ||
            shortKey == 'blockB' ||
            shortKey == 'blockC') {
          blocksSumKw += flowKw[shortKey]!;
        }
        continue;
      }
      final hourly = await cache.hourly24h(map.device);
      final kw = _kwFromHourlyOrMonthly(
          hourly, energyCache[map.device]?.monthlyKwh ?? 0);
      if (kw <= 0) continue;
      final shortKey = key.split('.').last;
      flowKw[shortKey] = kw;
      flowValues[shortKey] = _formatMwFromKw(kw);
      if (shortKey == 'blockA' ||
          shortKey == 'blockB' ||
          shortKey == 'blockC') {
        blocksSumKw += kw;
      }
    }

    double plantLoadKw = flowKw['plantTotal'] ?? blocksSumKw;
    if (plantLoadKw <= 0 && mainDevice.isNotEmpty) {
      final hourly = await cache.hourly24h(mainDevice);
      plantLoadKw = _kwFromHourlyOrMonthly(
          hourly, energyCache[mainDevice]?.monthlyKwh ?? 0);
    }
    if (plantLoadKw > 0 && !flowValues.containsKey('plantTotal')) {
      flowValues['plantTotal'] = _formatMwFromKw(plantLoadKw);
    }

    final flowPcts = <String, String>{};
    final pctBase = plantLoadKw > 0 ? plantLoadKw : blocksSumKw;
    if (pctBase > 0) {
      for (final e in flowKw.entries) {
        flowPcts[e.key] = '${(e.value / pctBase * 100).toStringAsFixed(0)}%';
      }
    }
    final solarKw = flowKw['solar'] ?? 0;
    if (plantLoadKw > 0 && solarKw > 0) {
      flowPcts['solar'] =
          '${(solarKw / plantLoadKw * 100).toStringAsFixed(0)}% of Load';
    }

    String plantMdPct = '—';
    if (plantLoadKw > 0 && contractKw > 0) {
      plantMdPct =
          '${(plantLoadKw / contractKw * 100).toStringAsFixed(0)}% of MD';
    }

    final flowValuesMonthly = <String, String>{};
    final flowPctsMonthly = <String, String>{};
    double blocksSumMonthlyKwh = 0.0;
    final monthlyKwhByKey = <String, double>{};
    for (final key in flowKeys) {
      final map = _m(mappings, key);
      if (map == null || !map.isMapped) continue;
      final kwh = energyCache[map.device]?.monthlyKwh ?? 0.0;
      if (kwh <= 0) continue;
      final shortKey = key.split('.').last;
      monthlyKwhByKey[shortKey] = kwh;
      flowValuesMonthly[shortKey] = _formatMwFromKw(kwh);
      if (shortKey == 'blockA' ||
          shortKey == 'blockB' ||
          shortKey == 'blockC') {
        blocksSumMonthlyKwh += kwh;
      }
    }
    if (blocksSumMonthlyKwh > 0) {
      if (!flowValuesMonthly.containsKey('plantTotal')) {
        flowValuesMonthly['plantTotal'] = _formatMwFromKw(blocksSumMonthlyKwh);
      }
      for (final e in monthlyKwhByKey.entries) {
        if (e.key == 'solar') continue;
        flowPctsMonthly[e.key] =
            '${(e.value / blocksSumMonthlyKwh * 100).toStringAsFixed(0)}%';
      }
      final solarMonthly = monthlyKwhByKey['solar'] ?? 0.0;
      if (solarMonthly > 0) {
        flowPctsMonthly['solar'] =
            '${(solarMonthly / blocksSumMonthlyKwh * 100).toStringAsFixed(0)}% of Load';
      }
    }

    final loadHourly = loadDevice.isNotEmpty
        ? await cache.hourly24h(loadDevice)
        : _PeccRequestCache._emptyHourly;
    double loadKw = _latestMdKw(loadHourly);
    if (loadKw <= 0) loadKw = plantLoadKw;
    if (loadKw <= 0 && loadDevice.isNotEmpty) {
      final m = energyCache[loadDevice]?.monthlyKwh ?? 0;
      loadKw = m > 0 ? m / (30 * 24) : 0.0;
    }
    final sidebarLoad = _formatMwFromKw(loadKw);
    final loadPct =
        contractKw > 0 && loadKw > 0 ? loadKw / contractKw * 100 : 0;
    final sidebarLoadSub = loadKw > 0 && contractKw > 0
        ? '${loadPct.toStringAsFixed(0)}% of Contract Capacity (${contractMw.toStringAsFixed(2)} MW)'
        : '—';

    final mdPct = mdKw > 0 && contractKw > 0 ? mdKw / contractKw * 100 : 0.0;
    final lastMonthMd = mdBillingDevice.isNotEmpty
        ? await _fetchLastMonthMaxDemandKw(mdBillingDevice)
        : 0.0;
    final sidebarMd = mdKw > 0 ? '${mdKw.toStringAsFixed(1)} kW' : '—';
    String sidebarMdSub = '—';
    if (mdKw > 0 && lastMonthMd > 0) {
      final deltaPct = (mdKw - lastMonthMd) / lastMonthMd * 100;
      final sign = deltaPct >= 0 ? '↑' : '↓';
      sidebarMdSub =
          '$sign ${deltaPct.abs().toStringAsFixed(1)}% vs Last Month';
    } else if (mdKw > 0 &&
        contractKw > 0 &&
        (contractKw - 2100.0).abs() > 0.01) {
      sidebarMdSub =
          '${mdPct.toStringAsFixed(1)}% of Contract Capacity (${contractKw.toStringAsFixed(0)} kW)';
    }

    final pfMysql = includeCharts && heroEnergyDevice.isNotEmpty
        ? await cache.powerFactor(heroEnergyDevice)
        : 0.0;
    String sidebarPf = '—';
    String sidebarPfSub = '—';
    if (pfMysql > 0) {
      sidebarPf = pfMysql.toStringAsFixed(2);
      sidebarPfSub = 'From MySQL hourly';
    } else if (pfValue > 0) {
      sidebarPf = pfValue.toStringAsFixed(2);
      sidebarPfSub = 'From bill simulator';
    }

    String sidebarSolarPct = '—';
    String sidebarSolarSub = '—';
    if (dailyKwh > 0 && solarDaily > 0) {
      sidebarSolarPct = '${(solarDaily / dailyKwh * 100).toStringAsFixed(0)}%';
      sidebarSolarSub = yesterdaySolarKwh > 0
          ? 'vs Yesterday ${_formatDeltaPct(solarDaily / dailyKwh * 100, yesterdaySolarKwh / (yesterdayKwh > 0 ? yesterdayKwh : dailyKwh) * 100)}'
          : '—';
    } else if (sidebarSolarMap != null && sidebarSolarMap.isMapped) {
      final s = energyCache[sidebarSolarMap.device]?.dailyKwh ?? 0;
      final t = dailyKwh > 0 ? s / dailyKwh * 100 : 0;
      if (t > 0) sidebarSolarPct = '${t.toStringAsFixed(0)}%';
    }

    final blockRows = <PeccBlockRow>[];
    var blockSum = 0.0;
    final blockEntries = <(String label, double kwh)>[];
    const blockOrder = [
      ('flow.blockB', 'Block B'),
      ('flow.blockA', 'Block A'),
      ('flow.blockC', 'Block C'),
    ];
    for (final (key, fallback) in blockOrder) {
      final map = _m(mappings, key);
      if (map == null || !map.isMapped) continue;
      final kwh = energyCache[map.device]?.dailyKwh ?? 0;
      if (kwh <= 0) continue;
      blockEntries.add((map.label.isNotEmpty ? map.label : fallback, kwh));
      blockSum += kwh;
    }
    final othersKwh = dailyKwh > blockSum ? dailyKwh - blockSum : 0.0;
    if (othersKwh > 0.5) {
      blockEntries.add(('Others', othersKwh));
      blockSum += othersKwh;
    }
    if (blockSum > 0) {
      for (final e in blockEntries) {
        blockRows.add(PeccBlockRow(
          label: e.$1,
          kwhDisplay: '${_formatKwhRaw(e.$2)} kWh',
          fraction: e.$2 / blockSum,
        ));
      }
    }
    final blockTotal =
        blockSum > 0 ? '${_formatKwhRaw(blockSum)} kWh (100%)' : '—';

    final hasData = dailyKwh > 0 ||
        solarDaily > 0 ||
        heroBill.totalBill > 0 ||
        flowValues.isNotEmpty;
    final now = DateTime.now();
    final lastUpdated =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final loadHourlyChart = loadChartDevice.isNotEmpty
        ? await cache.hourly24h(loadChartDevice)
        : _PeccRequestCache._emptyHourly;
    final mdHourlyChart =
        mdChartDevice.isNotEmpty && mdChartDevice != loadChartDevice
            ? await cache.hourly24h(mdChartDevice)
            : loadHourlyChart;
    final chartLoadKw = loadHourlyChart.powerKw;
    final chartMdKw = mdHourlyChart.mdKw.isNotEmpty
        ? mdHourlyChart.mdKw
        : loadHourlyChart.mdKw;
    final chartLoadLabels = loadHourlyChart.labels;
    final chartMdLabels = mdHourlyChart.labels.isNotEmpty
        ? mdHourlyChart.labels
        : loadHourlyChart.labels;
    final chartMdCumulativeKw = _cumulativeMaxKw(chartMdKw);

    final solarHourly = includeCharts && solarChartDevice.isNotEmpty
        ? await cache.hourlySolar(solarChartDevice)
        : _PeccRequestCache._emptyLabeled;
    final chartSolarKw = solarHourly.values;
    final chartSolarLabels = solarHourly.labels;

    final loadDaily = includeCharts && loadChartDevice.isNotEmpty
        ? await cache.dailySeries(loadChartDevice)
        : _PeccRequestCache._emptyLabeled;
    final mdDaily = includeCharts && mdChartDevice.isNotEmpty
        ? await cache.dailyMaxDemand(mdChartDevice)
        : _PeccRequestCache._emptyLabeled;
    final solarDailyChart = includeCharts && solarChartDevice.isNotEmpty
        ? await cache.dailySeries(solarChartDevice)
        : _PeccRequestCache._emptyLabeled;

    final chartLoad = _normalizeSeries(chartLoadKw);
    final chartMd = _mdProfileTodayKw(chartMdKw, contractKw);
    final chartSolar = _normalizeSeries(chartSolarKw);

    // ── Power Flow Monthly (MTD) — Daily/Monthly toggle ─────────────────────
    final heroMonthlyRaw = energyCache[heroEnergyDevice]?.monthlyKwh ?? 0;
    final solarMonthlyRaw = energyCache[solarDevice]?.monthlyKwh ?? 0.0;
    final pfSplitMonthly =
        _pfSplitTotals(hero0: heroMonthlyRaw, solar: solarMonthlyRaw);
    final monthlyCost = heroBill.totalBill > 0
        ? heroBill.totalBill
        : (pfSplitMonthly.grid > 0
            ? pfSplitMonthly.grid * _fallbackTariffRmPerKwh
            : (dailyCost > 0 ? dailyCost * now.day : 0.0));
    final carbonMonthlyT = pfSplitMonthly.grid > 0 && emissionFactor > 0
        ? (pfSplitMonthly.grid * emissionFactor) / 1000.0
        : 0.0;

    final pfBlocksMonthly = <PeccPowerFlowBlock>[
      for (final e in [('A', 'blockA'), ('B', 'blockB'), ('C', 'blockC')])
        _pfBlockFromParts(
          label: 'BLOCK ${e.$1}',
          total: _monthlyMappedKwh(mappings, energyCache, '${e.$2}.total'),
          grid: _monthlyMappedKwh(mappings, energyCache, '${e.$2}.gridImport'),
          solar: _monthlyMappedKwh(mappings, energyCache, '${e.$2}.solar'),
        ),
    ];

    // Last-month totals for monthly deltas (best-effort; never fail full resolve).
    final prevMonthEnd = DateTime(now.year, now.month, 0);
    final prevDate =
        '${prevMonthEnd.year.toString().padLeft(4, '0')}-${prevMonthEnd.month.toString().padLeft(2, '0')}-${prevMonthEnd.day.toString().padLeft(2, '0')}';
    double lastMonthHero = 0;
    double lastMonthSolar = 0;
    try {
      if (includeCharts && heroEnergyDevice.isNotEmpty) {
        lastMonthHero =
            (await _fetchEnergy(heroEnergyDevice, date: prevDate)).monthlyKwh;
      }
      if (includeCharts && solarDevice.isNotEmpty) {
        lastMonthSolar =
            (await _fetchEnergy(solarDevice, date: prevDate)).monthlyKwh;
      }
    } catch (_) {}
    final ySplitMonthly =
        _pfSplitTotals(hero0: lastMonthHero, solar: lastMonthSolar);
    final powerFlowHeroDeltasMonthly = [
      _heroDelta(pfSplitMonthly.total,
          ySplitMonthly.total > 0 ? ySplitMonthly.total : lastMonthHero),
      _heroDelta(pfSplitMonthly.solar, lastMonthSolar),
      _heroDelta(pfSplitMonthly.grid, ySplitMonthly.grid),
      const PeccHeroDelta(), // MTD bill vs last month bill not fetched here
      _heroDelta(
        carbonMonthlyT,
        ySplitMonthly.grid > 0 && emissionFactor > 0
            ? (ySplitMonthly.grid * emissionFactor) / 1000.0
            : 0,
        lowerIsBetter: true,
      ),
    ];
    final pfInsightsMonthly = _buildPfInsights(
      total: pfSplitMonthly.total,
      solar: pfSplitMonthly.solar,
      costToday: monthlyCost,
      costYesterday: 0,
      blocks: pfBlocksMonthly,
      costCompareLabel: 'last month',
    );

    // Monthly trend = daily series for this month (from /energyDetails/data/.../daily).
    // Grid + Solar mapped; Total = Grid + Solar per day.
    var pfTrendTotalMonthly = <double>[];
    var pfTrendGridMonthly = <double>[];
    var pfTrendSolarMonthly = <double>[];
    var pfTrendMonthlyLabels = <String>[];
    try {
      final trendGridDaily = includeCharts && trendGridDevice.isNotEmpty
          ? await cache.dailySeries(trendGridDevice)
          : _PeccRequestCache._emptyLabeled;
      final trendSolarDaily = includeCharts && trendSolarDevice.isNotEmpty
          ? await cache.dailySeries(trendSolarDevice)
          : _PeccRequestCache._emptyLabeled;

      // Align grid + solar by calendar day; fall back to solar chart daily when
      // trend.solar has no per-day rows (hourly trend still works for Today view).
      var gridByDay = _dailyKwhByCalendarDay(trendGridDaily, now);
      var solarByDay = _dailyKwhByCalendarDay(trendSolarDaily, now);
      if (!solarByDay.values.any((v) => v > 0)) {
        final chartSolarByDay = _dailyKwhByCalendarDay(solarDailyChart, now);
        if (chartSolarByDay.values.any((v) => v > 0))
          solarByDay = chartSolarByDay;
      }
      if (!solarByDay.values.any((v) => v > 0) && solarDevice.isNotEmpty) {
        final heroSolarDaily = await cache.dailySeries(solarDevice);
        final heroSolarByDay = _dailyKwhByCalendarDay(heroSolarDaily, now);
        if (heroSolarByDay.values.any((v) => v > 0))
          solarByDay = heroSolarByDay;
      }
      final aligned = _buildAlignedMonthlyTrend(
          gridByDay: gridByDay, solarByDay: solarByDay, when: now);
      pfTrendGridMonthly = aligned.grid;
      pfTrendSolarMonthly = aligned.solar;
      pfTrendTotalMonthly = List.generate(
        aligned.grid.length,
        (i) => aligned.grid[i] + aligned.solar[i],
      );
      pfTrendMonthlyLabels = aligned.labels;
    } catch (_) {}

    final tnbKwhToday =
        _tnbKwhToday(mappings, energyCache, gridFallback: pfSplit.grid);
    final tnbKwhMonthly = _tnbKwhMonthly(mappings, energyCache,
        gridFallback: pfSplitMonthly.grid);

    return PeccLiveData(
      energyToday:
          _formatKwh(pfSplit.total > 0 ? pfSplit.total : heroEnergyKwhEff),
      energyCostToday: _formatRm(dailyCost),
      heroTotalEnergyToday:
          pfSplit.total > 0 ? '${_formatKwhRaw(pfSplit.total)} kWh' : '—',
      heroSolarToday:
          pfSplit.solar > 0 ? '${_formatKwhRaw(pfSplit.solar)} kWh' : '—',
      heroGridImportToday:
          pfSplit.grid > 0 ? '${_formatKwhRaw(pfSplit.grid)} kWh' : '—',
      heroEnergyCostToday: dailyCost > 0
          ? 'RM ${_addThousands(dailyCost.toStringAsFixed(2))}'
          : '—',
      heroCarbonToday:
          carbonT > 0 ? '${carbonT.toStringAsFixed(1)} tCO₂e' : '—',
      heroDeltas: heroDeltas,
      powerFlowHeroDeltas: powerFlowHeroDeltas,
      sidebarCurrentLoad: sidebarLoad,
      sidebarCurrentLoadSub: sidebarLoadSub,
      sidebarMaxDemand: sidebarMd,
      sidebarMaxDemandSub: sidebarMdSub,
      sidebarMdBarPct: (mdPct / 100).clamp(0.0, 1.5),
      sidebarPowerFactor: sidebarPf,
      sidebarPowerFactorSub: sidebarPfSub,
      sidebarSolarContribution: sidebarSolarPct,
      sidebarSolarSub: sidebarSolarSub,
      sidebarPlantHealth: hasData ? 'Healthy' : '—',
      sidebarPlantHealthSub:
          hasData ? 'All systems normal' : 'Awaiting mapped data',
      flowValues: flowValues,
      flowPcts: flowPcts,
      plantMdPct: plantMdPct,
      flowValuesMonthly: flowValuesMonthly,
      flowPctsMonthly: flowPctsMonthly,
      alertCritical: 0,
      alertWarning: 0,
      alertInfo: 0,
      todayEvents: const [],
      chartLoadProfile: chartLoad,
      chartMdProfile: chartMd,
      chartSolarProfile: chartSolar,
      chartLoadKw: chartLoadKw,
      chartMdKw: chartMdKw,
      chartMdCumulativeKw: chartMdCumulativeKw,
      chartSolarKw: chartSolarKw,
      chartLoadDailyKwh: loadDaily.values,
      chartMdDailyMaxKw: mdDaily.values,
      chartSolarDailyKwh: solarDailyChart.values,
      chartLoadLabels: chartLoadLabels,
      chartMdLabels: chartMdLabels,
      chartSolarLabels: chartSolarLabels,
      chartLoadDailyLabels: loadDaily.labels,
      chartMdDailyLabels: mdDaily.labels,
      chartSolarDailyLabels: solarDailyChart.labels,
      chartContractKw: contractKw,
      blockBreakdown: blockRows,
      blockBreakdownTotal: blockTotal,
      lastUpdated: lastUpdated,
      totalCostMtd: _formatRm(heroBill.totalBill),
      totalEnergyMtd: _formatEnergy(energyCache[mainDevice]?.monthlyKwh ?? 0),
      hasData: hasData,
      pfPlantTotalKwh: pfSplit.total > 0 ? _formatKwhRaw(pfSplit.total) : '—',
      pfPlantSolarKwh: pfSplit.solar > 0 ? _formatKwhRaw(pfSplit.solar) : '—',
      pfPlantSolarPct: _pctOf(pfSplit.solar, pfSplit.total),
      pfPlantGridKwh: pfSplit.grid > 0 ? _formatKwhRaw(pfSplit.grid) : '—',
      pfPlantGridPct: _pctOf(pfSplit.grid, pfSplit.total),
      pfTnbKwh: tnbKwhToday > 0 ? _formatKwhRaw(tnbKwhToday) : '—',
      pfTnbHz: tnbHzVal > 0 ? tnbHzVal.toStringAsFixed(2) : '—',
      pfTnbPf: tnbPfVal > 0
          ? tnbPfVal.toStringAsFixed(2)
          : (pfValue > 0 ? pfValue.toStringAsFixed(2) : '—'),
      pfBlocks: pfBlocks.any((b) => b.totalRaw > 0) ? pfBlocks : const [],
      pfInsights: pfInsights,
      pfTrendTotal: pfTrendTotal.any((v) => v > 0) ? pfTrendTotal : const [],
      pfTrendGrid: pfTrendGrid.any((v) => v > 0) ? pfTrendGrid : const [],
      pfTrendSolar: pfTrendSolar.any((v) => v > 0) ? pfTrendSolar : const [],
      pfBlockBars: pfBlockBars,
      powerFlowHeroDeltasMonthly: powerFlowHeroDeltasMonthly,
      pfPlantTotalKwhMonthly:
          pfSplitMonthly.total > 0 ? _formatKwhRaw(pfSplitMonthly.total) : '—',
      pfPlantSolarKwhMonthly:
          pfSplitMonthly.solar > 0 ? _formatKwhRaw(pfSplitMonthly.solar) : '—',
      pfPlantSolarPctMonthly:
          _pctOf(pfSplitMonthly.solar, pfSplitMonthly.total),
      pfPlantGridKwhMonthly:
          pfSplitMonthly.grid > 0 ? _formatKwhRaw(pfSplitMonthly.grid) : '—',
      pfPlantGridPctMonthly: _pctOf(pfSplitMonthly.grid, pfSplitMonthly.total),
      pfTnbKwhMonthly: tnbKwhMonthly > 0 ? _formatKwhRaw(tnbKwhMonthly) : '—',
      pfHeroCostMonthly: monthlyCost > 0
          ? 'RM ${_addThousands(monthlyCost.toStringAsFixed(2))}'
          : '—',
      pfHeroCarbonMonthly: carbonMonthlyT > 0
          ? '${carbonMonthlyT.toStringAsFixed(1)} tCO₂e'
          : '—',
      pfBlocksMonthly: pfBlocksMonthly.any((b) => b.totalRaw > 0)
          ? pfBlocksMonthly
          : const [],
      pfInsightsMonthly: pfInsightsMonthly,
      pfTrendTotalMonthly: pfTrendTotalMonthly.any((v) => v > 0)
          ? pfTrendTotalMonthly
          : const [],
      pfTrendGridMonthly:
          pfTrendGridMonthly.any((v) => v > 0) ? pfTrendGridMonthly : const [],
      pfTrendSolarMonthly: pfTrendSolarMonthly.any((v) => v > 0)
          ? pfTrendSolarMonthly
          : const [],
      pfTrendMonthlyLabels: pfTrendMonthlyLabels,
    );
  }
}
