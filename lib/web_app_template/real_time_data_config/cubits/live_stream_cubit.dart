import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../models/discovery_models.dart';
import '../services/influx_discovery_service.dart';

/// Threshold: a tag is Live if InfluxDB returned a value for it within the last 2 minutes.
const _staleThreshold = Duration(minutes: 2);

class LiveStreamState {
  final Map<String, dynamic> values;
  final bool isLoading;
  final DateTime? lastUpdate;
  final Map<String, DateTime> keyTimestamps;
  final Set<String> reconnectingKeys;

  const LiveStreamState({
    this.values = const {},
    this.isLoading = false,
    this.lastUpdate,
    this.keyTimestamps = const {},
    this.reconnectingKeys = const {},
  });

  LiveStreamState copyWith({
    Map<String, dynamic>? values,
    bool? isLoading,
    DateTime? lastUpdate,
    Map<String, DateTime>? keyTimestamps,
    Set<String>? reconnectingKeys,
  }) =>
      LiveStreamState(
        values: values ?? this.values,
        isLoading: isLoading ?? this.isLoading,
        lastUpdate: lastUpdate ?? this.lastUpdate,
        keyTimestamps: keyTimestamps ?? this.keyTimestamps,
        reconnectingKeys: reconnectingKeys ?? this.reconnectingKeys,
      );

  bool isStale(String key) {
    final ts = keyTimestamps[key];
    if (ts == null) return true;
    return DateTime.now().difference(ts) > _staleThreshold;
  }
}

class LiveStreamCubit extends Cubit<LiveStreamState> {
  final InfluxDiscoveryService _influx;
  Timer? _pollTimer;
  List<InfluxTag> _tags = [];
  bool _fetching = false;

  LiveStreamCubit({InfluxDiscoveryService? influx})
      : _influx = influx ?? InfluxDiscoveryService(),
        super(const LiveStreamState());

  void startStreaming(List<InfluxTag> tags) {
    _tags = tags;
    _pollTimer?.cancel();
    _fetchValues();
    // Poll every 30s — history fallback is expensive; don't hammer the API.
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchValues());
  }

  void stopStreaming() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _fetchValues() async {
    if (_tags.isEmpty || _fetching || isClosed) return;
    _fetching = true;
    try {
      if (!isClosed) emit(state.copyWith(isLoading: true));
      final newValues = await _influx.getBatchRealtimeValues(_tags);
      if (isClosed) return;

      final now = DateTime.now();
      final updatedTimestamps = Map<String, DateTime>.from(state.keyTimestamps);
      for (final key in newValues.keys) {
        final v = newValues[key];
        if (v != null && v.toString().isNotEmpty) {
          updatedTimestamps[key] = now;
        }
      }

      emit(state.copyWith(
        values: {...state.values, ...newValues},
        isLoading: false,
        lastUpdate: now,
        keyTimestamps: updatedTimestamps,
      ));
    } catch (_) {
      if (!isClosed) emit(state.copyWith(isLoading: false));
    } finally {
      _fetching = false;
    }
  }

  Future<void> reconnectTag(InfluxTag tag) async {
    if (isClosed) return;
    final key = '${tag.measurement}.${tag.realMeasurement}.${tag.fieldName}';
    final reconnecting = Set<String>.from(state.reconnectingKeys)..add(key);
    emit(state.copyWith(reconnectingKeys: reconnecting));
    try {
      final result = await _influx.getBatchRealtimeValues([tag]);
      if (isClosed) return;
      final now = DateTime.now();
      final updatedTimestamps = Map<String, DateTime>.from(state.keyTimestamps);
      final v = result[key];
      if (v != null && v.toString().isNotEmpty) updatedTimestamps[key] = now;

      emit(state.copyWith(
        values: {...state.values, ...result},
        lastUpdate: now,
        keyTimestamps: updatedTimestamps,
        reconnectingKeys: Set<String>.from(state.reconnectingKeys)..remove(key),
      ));
    } catch (_) {
      if (!isClosed) {
        emit(state.copyWith(
          reconnectingKeys: Set<String>.from(state.reconnectingKeys)..remove(key),
        ));
      }
    }
  }

  @override
  Future<void> close() {
    _pollTimer?.cancel();
    return super.close();
  }
}
