/// Station pages under Equipment Monitoring (Sterilizer, Digester).
///
/// A station page has one card per equipment whose Equipment Settings
/// category is the station's — add an equipment under "Sterilizer" and the
/// Sterilizer page gains a card. How each card's readings are read (device,
/// measurement, field per point), the rules, and the page layout live in the
/// station's settings (Station Page Setting), shared by every account.

enum PointKind { analog, counter, digital }

/// One reading every line of a station has.
class StationPoint {
  const StationPoint({
    required this.key,
    required this.label,
    required this.short,
    required this.unit,
    required this.part,
    this.kind = PointKind.analog,
    this.min = 0,
    this.max = 100,
    this.decimals = 1,
    this.optional = false,
  });

  final String key;
  final String label;
  final String short;
  final String unit;

  /// 'main' or 'sub' — which half of the card it belongs to.
  final String part;
  final PointKind kind;
  final double min;
  final double max;
  final int decimals;

  /// Not every mill measures it (e.g. temperature); an unmapped optional
  /// point is left off the card instead of flagged.
  final bool optional;
}

/// A station overview tile the layout can show or hide.
class KpiDef {
  const KpiDef(this.key, this.title);
  final String key;
  final String title;
}

/// What a station is: its name, which equipment category feeds it, the parts
/// of a line and the points every line has.
class StationDef {
  const StationDef({
    required this.key,
    required this.name,
    required this.mainPart,
    required this.subPart,
    required this.categoryWords,
    required this.points,
    required this.mainPoint,
    required this.kpis,
    this.subOnPoint,
    this.hoursPoint,
    this.tempPoint,
    this.defaultSources = const {},
    this.samples = const [],
    this.sampleLines = 4,
  });

  /// Where each point is read when a line has no mapping of its own:
  /// (device, measurement, field with `#` = the line's number). These are the
  /// mill's live devices, so a line shows real data before anyone maps it.
  final Map<String, (String, String, String)> defaultSources;

  /// Sample values per line (by position) for readings no device measures
  /// (or a device that returns nothing), so the page is never blank. Real
  /// data always wins where it exists.
  final List<Map<String, double>> samples;

  /// How many sample lines to show when no equipment is in this category yet.
  final int sampleLines;

  PointSource? defaultSource(String point, int lineNumber) {
    final d = defaultSources[point];
    if (d == null) return null;
    return PointSource(device: d.$1, measurement: d.$2, field: d.$3.replaceAll('#', '$lineNumber'));
  }

  double? sample(String point, int index) => samples.isEmpty ? null : samples[index % samples.length][point];

  /// URL / settings key: 'sterilizer' or 'digester'.
  final String key;
  final String name;

  /// What a line's two halves are called ("Digester" + "Screw press";
  /// a sterilizer has no second part).
  final String mainPart;
  final String? subPart;

  /// An equipment belongs to this station when its category (or device type)
  /// contains one of these words, case-insensitive.
  final List<String> categoryWords;
  final List<StationPoint> points;

  /// Says whether the main part is running, and draws the trend chart.
  final String mainPoint;

  /// Says whether the second part is running.
  final String? subOnPoint;

  /// Running-hours counter feeding the service bar.
  final String? hoursPoint;

  /// Temperature shown in the picture corner and checked by the alert.
  final String? tempPoint;

  final List<KpiDef> kpis;

  StationPoint? point(String? k) {
    for (final p in points) {
      if (p.key == k) return p;
    }
    return null;
  }

  bool matches(Map<String, dynamic> equipment) {
    final text = [
      equipment['equipment_category'],
      equipment['equipmentCategory'],
      equipment['device_type'],
      equipment['equipment_type'],
    ].whereType<Object>().join(' ').toLowerCase();
    return categoryWords.any(text.contains);
  }
}

const kSterilizerStation = StationDef(
  key: 'sterilizer',
  name: 'Sterilizer',
  mainPart: 'Sterilizer',
  subPart: null,
  categoryWords: ['steriliz'],
  mainPoint: 'pressure',
  tempPoint: 'temperature',
  sampleLines: 4,
  defaultSources: {
    'pressure': ('SAMYSK_POM_250045', 'PSTR_bar', 'stp#'),
    'temperature': ('SAMYSK_POM_250047', 'PSTR_temp', 'stp#'),
  },
  samples: [
    {'pressure': 2.9, 'temperature': 138},
    {'pressure': 0.02, 'temperature': 62},
    {'pressure': 2.6, 'temperature': 134},
    {'pressure': 1.4, 'temperature': 121},
  ],
  points: [
    StationPoint(key: 'pressure', label: 'Sterilizer pressure', short: 'Pressure', unit: 'bar', part: 'main', min: 0, max: 4, decimals: 2),
    StationPoint(key: 'temperature', label: 'Sterilizer temperature', short: 'Temperature', unit: '°C', part: 'main', min: 0, max: 160, decimals: 0, optional: true),
  ],
  kpis: [
    KpiDef('running', 'Sterilizers running'),
    KpiDef('avgMain', 'Avg pressure (running)'),
    KpiDef('maxMain', 'Highest pressure'),
    KpiDef('avgTemp', 'Avg temperature (running)'),
    KpiDef('alerts', 'Active alarms'),
  ],
);

const kDigesterStation = StationDef(
  key: 'digester',
  name: 'Digester & Press',
  mainPart: 'Digester',
  subPart: 'Screw press',
  categoryWords: ['digest'],
  mainPoint: 'digCurrent',
  subOnPoint: 'pressCurrent',
  hoursPoint: 'pressHours',
  tempPoint: 'digTemp',
  sampleLines: 5,
  defaultSources: {
    'digCurrent': ('SAMYSK_POM_250034', 'PDIG_ma_A', 'dig#'),
    'pressCurrent': ('SAMYSK_POM_250034', 'PDIG_ma_A', 'press#'),
    'pressHours': ('SAMYSK_POM_250034', 'PDIG_rh_hr', 'press#'),
  },
  // From the station page design: digester temperature and level switches are
  // not measured on SmartMill yet, so these stand in until they are.
  samples: [
    {'digCurrent': 49.1, 'digTemp': 96, 'levelFull': 1, 'level70': 1, 'pressCurrent': 42.6, 'pressHours': 1136.7},
    {'digCurrent': 0.1, 'digTemp': 72, 'levelFull': 0, 'level70': 0, 'pressCurrent': 0, 'pressHours': 886.1},
    {'digCurrent': 27.9, 'digTemp': 91, 'levelFull': 0, 'level70': 1, 'pressCurrent': 31.2, 'pressHours': 1633.6},
    {'digCurrent': 0.2, 'digTemp': 34, 'levelFull': 0, 'level70': 0, 'pressCurrent': 0, 'pressHours': 0},
    {'digCurrent': 48.5, 'digTemp': 95, 'levelFull': 1, 'level70': 1, 'pressCurrent': 44.1, 'pressHours': 511.5},
  ],
  points: [
    StationPoint(key: 'digCurrent', label: 'Digester motor current', short: 'Motor current', unit: 'A', part: 'main', min: 0, max: 80),
    StationPoint(key: 'digTemp', label: 'Digester temperature', short: 'Temperature', unit: '°C', part: 'main', min: 0, max: 120, decimals: 0, optional: true),
    StationPoint(key: 'levelFull', label: 'Full level switch', short: 'Full switch', unit: '', part: 'main', kind: PointKind.digital, decimals: 0, optional: true),
    StationPoint(key: 'level70', label: '70% level switch', short: '70% switch', unit: '', part: 'main', kind: PointKind.digital, decimals: 0, optional: true),
    StationPoint(key: 'pressCurrent', label: 'Screw press motor current', short: 'Motor current', unit: 'A', part: 'sub', min: 0, max: 80),
    StationPoint(key: 'pressHours', label: 'Screw press running hours', short: 'Running hours', unit: 'hrs', part: 'sub', kind: PointKind.counter, decimals: 1, optional: true),
  ],
  kpis: [
    KpiDef('running', 'Digesters running'),
    KpiDef('sumMain', 'Total digester load'),
    KpiDef('avgTemp', 'Avg digester temp'),
    KpiDef('levelFull', 'Level full'),
    KpiDef('sumSub', 'Total press load'),
    KpiDef('sumHours', 'Press hours total'),
    KpiDef('alerts', 'Active alarms'),
  ],
);

const kStations = [kSterilizerStation, kDigesterStation];

StationDef? stationByKey(String? key) =>
    key == 'digester' ? kDigesterStation : key == 'sterilizer' ? kSterilizerStation : null;

/// Where one point of one line is read from.
class PointSource {
  const PointSource({required this.device, required this.measurement, required this.field});

  final String device;
  final String measurement;
  final String field;

  bool get isSet => device.isNotEmpty && field.isNotEmpty;

  factory PointSource.fromJson(Map<String, dynamic>? j) => PointSource(
        device: (j?['device'] ?? '').toString(),
        measurement: (j?['measurement'] ?? '').toString(),
        field: (j?['field'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'device': device, 'measurement': measurement, 'field': field};

  static const empty = PointSource(device: '', measurement: '', field: '');
}

/// Per-line settings: shown, order, the second part's name, service interval
/// and the point sources.
class LineSetting {
  LineSetting({this.shown = true, this.order, this.subName = '', this.serviceHours = 2000, Map<String, PointSource>? sources})
      : sources = sources ?? {};

  bool shown;
  int? order;

  /// Name of the line's second part on the card ("Press 1"); blank = derived.
  String subName;
  double serviceHours;
  final Map<String, PointSource> sources;

  factory LineSetting.fromJson(Map<String, dynamic>? j) => LineSetting(
        shown: j?['shown'] != false,
        order: (j?['order'] as num?)?.toInt(),
        subName: (j?['subName'] ?? '').toString(),
        serviceHours: (j?['serviceHours'] as num?)?.toDouble() ?? 2000,
        sources: {
          for (final e in ((j?['sources'] as Map?) ?? {}).entries)
            e.key.toString(): PointSource.fromJson(Map<String, dynamic>.from(e.value as Map)),
        },
      );

  Map<String, dynamic> toJson() => {
        'shown': shown,
        if (order != null) 'order': order,
        'subName': subName,
        'serviceHours': serviceHours,
        'sources': {for (final e in sources.entries) e.key: e.value.toJson()},
      };
}

/// The station's saved settings: rules, alerts, layout, and per-line mapping.
class StationSettings {
  StationSettings(this.station, Map<String, dynamic> j)
      : prefix = _s(j, 'prefix', 'P1'),
        title = _s(j, 'title', station.key == 'digester' ? 'Digester & Press' : 'Sterilizer'),
        suffix = _s(j, 'suffix', 'Station'),
        showSite = j['showSite'] != false,
        showUpdated = j['showUpdated'] != false,
        tbDevices = j['tbDevices'] != false,
        tbMode = j['tbMode'] != false,
        tbRange = j['tbRange'] != false,
        tbRefresh = j['tbRefresh'] != false,
        tbAi = j['tbAi'] != false,
        defaultRange = _s(j, 'defaultRange', '6h'),
        refreshSec = (j['refreshSec'] as num?)?.toInt() ?? 10,
        overviewTitle = _s(j, 'overviewTitle', 'Station overview'),
        kpiShown = ((j['kpiShown'] as List?)?.map((e) => e.toString()).toSet()) ?? station.kpis.map((k) => k.key).toSet(),
        cardsTitle = _s(j, 'cardsTitle', station.key == 'digester' ? 'Digester & screw press lines' : 'Sterilizer lines'),
        cardChips = j['cardChips'] != false,
        cardLegend = j['cardLegend'] != false,
        cardPicture = j['cardPicture'] != false,
        cardTags = j['cardTags'] != false,
        perRow = (j['perRow'] as num?)?.toInt() ?? 0,
        chartShow = j['chartShow'] != false,
        chartTitle = _s(j, 'chartTitle', station.key == 'digester' ? 'All equipment — digester current' : 'All equipment — sterilizer pressure'),
        mainOnAbove = _n(j, 'mainOnAbove', station.key == 'digester' ? 5 : 0.3),
        subOnAbove = _n(j, 'subOnAbove', 5),
        runLabel = _s(j, 'runLabel', 'Running'),
        stopLabel = _s(j, 'stopLabel', 'Stopped'),
        partLabel = _s(j, 'partLabel', station.key == 'digester' ? 'Press off' : 'Partial'),
        alertTemp = j['alertTemp'] != false,
        alertMin = _n(j, 'alertMin', station.key == 'digester' ? 90 : 120),
        alertMax = _n(j, 'alertMax', station.key == 'digester' ? 100 : 145),
        alertTempText = _s(j, 'alertTempText', 'Temperature out of range'),
        alertSvc = j['alertSvc'] != false,
        servicePct = _n(j, 'servicePct', 90),
        alertSvcText = _s(j, 'alertSvcText', 'Service due soon'),
        ranges = {
          for (final e in ((j['ranges'] as Map?) ?? {}).entries)
            e.key.toString(): [
              ((e.value as Map)['min'] as num?)?.toDouble() ?? 0,
              ((e.value as Map)['max'] as num?)?.toDouble() ?? 100,
            ],
        },
        lines = {
          for (final e in ((j['lines'] as Map?) ?? {}).entries)
            e.key.toString(): LineSetting.fromJson(Map<String, dynamic>.from(e.value as Map)),
        };

  factory StationSettings.defaults(StationDef s) => StationSettings(s, const {});
  factory StationSettings.fromJson(StationDef s, Map<String, dynamic>? j) => StationSettings(s, j ?? const {});
  StationSettings copy() => StationSettings.fromJson(station, toJson());

  final StationDef station;

  // ── title & toolbar ──
  String prefix, title, suffix;
  bool showSite, showUpdated, tbDevices, tbMode, tbRange, tbRefresh, tbAi;
  String defaultRange;
  int refreshSec;

  // ── overview ──
  String overviewTitle;
  Set<String> kpiShown;

  // ── cards ──
  String cardsTitle;
  bool cardChips, cardLegend, cardPicture, cardTags;
  int perRow;

  // ── chart ──
  bool chartShow;
  String chartTitle;

  // ── rules ──
  double mainOnAbove, subOnAbove;
  String runLabel, stopLabel, partLabel;
  bool alertTemp;
  double alertMin, alertMax;
  String alertTempText;
  bool alertSvc;
  double servicePct;
  String alertSvcText;

  /// Gauge range overrides per point key: [min, max].
  final Map<String, List<double>> ranges;

  /// Keyed by equipment id.
  final Map<String, LineSetting> lines;

  String get fullTitle => [if (prefix.trim().isNotEmpty) '${prefix.trim()} -', title, suffix].where((s) => s.trim().isNotEmpty).join(' ');

  LineSetting line(String equipmentId) => lines.putIfAbsent(equipmentId, () => LineSetting());

  double minOf(StationPoint p) => ranges[p.key]?[0] ?? p.min;
  double maxOf(StationPoint p) => ranges[p.key]?[1] ?? p.max;

  static String _s(Map<String, dynamic> j, String k, String fb) {
    final v = j[k];
    return v is String && v.trim().isNotEmpty ? v : fb;
  }

  static double _n(Map<String, dynamic> j, String k, double fb) => (j[k] as num?)?.toDouble() ?? fb;

  Map<String, dynamic> toJson() => {
        'prefix': prefix,
        'title': title,
        'suffix': suffix,
        'showSite': showSite,
        'showUpdated': showUpdated,
        'tbDevices': tbDevices,
        'tbMode': tbMode,
        'tbRange': tbRange,
        'tbRefresh': tbRefresh,
        'tbAi': tbAi,
        'defaultRange': defaultRange,
        'refreshSec': refreshSec,
        'overviewTitle': overviewTitle,
        'kpiShown': kpiShown.toList(),
        'cardsTitle': cardsTitle,
        'cardChips': cardChips,
        'cardLegend': cardLegend,
        'cardPicture': cardPicture,
        'cardTags': cardTags,
        'perRow': perRow,
        'chartShow': chartShow,
        'chartTitle': chartTitle,
        'mainOnAbove': mainOnAbove,
        'subOnAbove': subOnAbove,
        'runLabel': runLabel,
        'stopLabel': stopLabel,
        'partLabel': partLabel,
        'alertTemp': alertTemp,
        'alertMin': alertMin,
        'alertMax': alertMax,
        'alertTempText': alertTempText,
        'alertSvc': alertSvc,
        'servicePct': servicePct,
        'alertSvcText': alertSvcText,
        'ranges': {for (final e in ranges.entries) e.key: {'min': e.value[0], 'max': e.value[1]}},
        'lines': {for (final e in lines.entries) e.key: e.value.toJson()},
      };
}
