class InfluxTag {
  /// Historically doubles as the owning device's id, not a real Influx
  /// measurement name — kept as-is since other code already relies on that.
  final String measurement;
  final String fieldName;
  final String tagName;
  final String unit;
  /// The field's real Influx measurement (e.g. "PSTR_psi"), when the source
  /// client has more than one and the backend could tell them apart. Empty
  /// for a client with one fixed measurement, where [measurement] already
  /// doubling as the device id is unambiguous.
  final String realMeasurement;
  dynamic lastValue;
  DateTime? lastUpdate;

  InfluxTag({
    required this.measurement,
    required this.fieldName,
    this.tagName = '',
    this.unit = '',
    this.realMeasurement = '',
    this.lastValue,
    this.lastUpdate,
  });

  Map<String, dynamic> toMap() => {
        'measurement': measurement,
        'fieldName': fieldName,
        'tagName': tagName,
        'unit': unit,
        'realMeasurement': realMeasurement,
        'lastValue': lastValue?.toString(),
        'lastUpdate': lastUpdate?.toIso8601String(),
      };

  factory InfluxTag.fromMap(Map<String, dynamic> m) => InfluxTag(
        measurement: m['measurement'] ?? '',
        fieldName: m['fieldName'] ?? '',
        tagName: m['tagName'] ?? m['fieldName'] ?? '',
        unit: m['unit'] ?? '',
        realMeasurement: m['realMeasurement'] ?? '',
        lastValue: m['lastValue'],
        lastUpdate: m['lastUpdate'] != null ? DateTime.tryParse(m['lastUpdate']) : null,
      );
}

class DiscoveredDevice {
  final String deviceId;
  final String deviceName;
  String displayName;
  String? deviceType;
  final List<InfluxTag> tags;
  final String plantId;
  final String zoneId;
  String plantName;
  String zoneName;
  bool isApproved;
  bool isHidden;
  // MySQL enrichment fields
  final String siteId;
  final String machineId;
  final String machineName;
  final String lineId;
  final String lineName;
  final String parentId;
  final String parentName;

  DiscoveredDevice({
    required this.deviceId,
    required this.deviceName,
    required this.displayName,
    required this.tags,
    required this.plantId,
    required this.zoneId,
    this.deviceType,
    this.plantName = '',
    this.zoneName = '',
    this.isApproved = false,
    this.isHidden = false,
    this.siteId = '',
    this.machineId = '',
    this.machineName = '',
    this.lineId = '',
    this.lineName = '',
    this.parentId = '',
    this.parentName = '',
  });

  Map<String, dynamic> toMap() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'displayName': displayName,
        'deviceType': deviceType ?? '',
        'tags': tags.map((t) => t.toMap()).toList(),
        'plantId': plantId,
        'zoneId': zoneId,
        'plantName': plantName,
        'zoneName': zoneName,
        'isApproved': isApproved,
        'isHidden': isHidden,
        'siteId': siteId,
        'machineId': machineId,
        'machineName': machineName,
        'lineId': lineId,
        'lineName': lineName,
        'parentId': parentId,
        'parentName': parentName,
      };

  factory DiscoveredDevice.fromMap(Map<String, dynamic> m) => DiscoveredDevice(
        deviceId: m['deviceId'] ?? '',
        deviceName: m['deviceName'] ?? '',
        displayName: m['displayName'] ?? m['deviceName'] ?? '',
        deviceType: (m['deviceType'] as String?)?.isNotEmpty == true ? m['deviceType'] : null,
        tags: (m['tags'] as List<dynamic>? ?? [])
            .map((t) => InfluxTag.fromMap(Map<String, dynamic>.from(t)))
            .toList(),
        plantId: m['plantId'] ?? '',
        zoneId: m['zoneId'] ?? '',
        plantName: m['plantName'] ?? '',
        zoneName: m['zoneName'] ?? '',
        isApproved: m['isApproved'] ?? false,
        isHidden: m['isHidden'] ?? false,
        siteId: m['siteId'] ?? '',
        machineId: m['machineId'] ?? '',
        machineName: m['machineName'] ?? '',
        lineId: m['lineId'] ?? '',
        lineName: m['lineName'] ?? '',
        parentId: m['parentId'] ?? '',
        parentName: m['parentName'] ?? '',
      );
}

class LiveTagData {
  final String tagName;
  final String field;
  final double value;
  final String unit;
  final String status;
  final DateTime lastUpdate;

  const LiveTagData({
    required this.tagName,
    required this.field,
    required this.value,
    required this.unit,
    required this.status,
    required this.lastUpdate,
  });

  factory LiveTagData.fromMap(Map<String, dynamic> m) => LiveTagData(
        tagName: m['tag_name'] ?? '',
        field: m['field'] ?? '',
        value: (m['value'] as num?)?.toDouble() ?? 0.0,
        unit: m['unit'] ?? '',
        status: m['status'] ?? 'Active',
        lastUpdate: DateTime.tryParse(m['last_update'] ?? '') ?? DateTime.now(),
      );
}
