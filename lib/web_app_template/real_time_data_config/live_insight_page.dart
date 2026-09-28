import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'cubits/discovery_cubit.dart';
import 'cubits/live_stream_cubit.dart';
import 'models/discovery_models.dart';
import 'services/influx_discovery_service.dart';

class DeviceLiveInsightPage extends StatelessWidget {
  const DeviceLiveInsightPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _LiveInsightContent();
  }
}

class _LiveInsightContent extends StatefulWidget {
  const _LiveInsightContent();
  @override
  State<_LiveInsightContent> createState() => _LiveInsightContentState();
}

class _LiveInsightContentState extends State<_LiveInsightContent> {
  DiscoveredDevice? _selected;
  LiveStreamCubit? _streamCubit;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  // '' = every measurement. Narrows the table to one real Influx measurement
  // when a device has several — the same field name (e.g. "stp1") can exist
  // under more than one, and this is the filter layer to tell them apart
  // instead of scrolling past what looks like duplicate rows.
  String _measurementFilter = '';
  bool _autoMode = false;
  Timer? _countdownTimer;
  int _secondsLeft = 60;

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() => _secondsLeft = 60);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _secondsLeft--;
        if (_secondsLeft <= 0) _secondsLeft = 60;
      });
    });
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
    setState(() => _secondsLeft = 60);
  }

  void _selectDevice(DiscoveredDevice d) {
    _streamCubit?.close();
    setState(() {
      _selected = d;
      _streamCubit = LiveStreamCubit()..startStreaming(d.tags);
      _measurementFilter = ''; // a new device has its own set of measurements
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _streamCubit?.close();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DiscoveryCubit>();
    return Container(
      color: const Color(0xFF020B2D),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header + Toolbar ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dashboard / Real-Time Data Configurator / Live Insight',
                        style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text('Device Live Data Insight',
                        style: GoogleFonts.outfit(color: Colors.white, fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    if (_selected != null) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        _Badge('ID: ${_selected!.deviceId}', const Color(0xFF00D4FF)),
                        const SizedBox(width: 6),
                        _Badge('Plant: ${_selected!.plantName}', Colors.white38),
                        const SizedBox(width: 6),
                        _Badge('Zone: ${_selected!.zoneName}', Colors.white38),
                      ]),
                    ],
                  ],
                ),
                const Spacer(),
                // ── Toolbar (synchronized with Page 1) ────────────────────
                _TBtn('Discover All Fields', Icons.radar, const Color(0xFF00D4FF),
                    () => cubit.discoverAll()),
                const SizedBox(width: 8),
                _TBtn('Discover Now', Icons.refresh, Colors.white60,
                    () => cubit.refreshNow()),
                const SizedBox(width: 8),
                // Auto (1 min) — same pattern as Page 1
                GestureDetector(
                  onTap: () {
                    setState(() => _autoMode = !_autoMode);
                    if (_autoMode) {
                      cubit.startAutoDiscover();
                      _startCountdown();
                    } else {
                      cubit.stopAutoDiscover();
                      _stopCountdown();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: _autoMode ? const Color(0xFF39FF14) : Colors.white24,
                          width: 0.8),
                      borderRadius: BorderRadius.circular(8),
                      color: _autoMode
                          ? const Color(0xFF39FF14).withOpacity(0.08)
                          : Colors.transparent,
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.timer, size: 14,
                          color: _autoMode ? const Color(0xFF39FF14) : Colors.white38),
                      const SizedBox(width: 6),
                      Text(_autoMode ? 'Auto ON' : 'Auto (1 min)',
                          style: GoogleFonts.poppins(fontSize: 12,
                              color: _autoMode ? const Color(0xFF39FF14) : Colors.white38)),
                      if (_autoMode) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF39FF14).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${_secondsLeft}s',
                            style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: const Color(0xFF39FF14),
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // ── Stale cache banner ────────────────────────────────────────────
          BlocBuilder<DiscoveryCubit, DiscoveryState>(
            buildWhen: (p, n) => p.isFromCache != n.isFromCache || p.devices.length != n.devices.length,
            builder: (context, state) {
              if (!state.isFromCache || state.devices.isEmpty) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.orange.withOpacity(0.4)),
                ),
                child: Row(children: [
                  const Icon(Icons.history, color: Colors.orange, size: 15),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    'Showing cached data — devices may no longer exist in InfluxDB. Press Discover to sync.',
                    style: GoogleFonts.poppins(color: Colors.orange, fontSize: 12),
                  )),
                ]),
              );
            },
          ),

          // ── Device selector tabs (Active devices only) ───────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: BlocBuilder<DiscoveryCubit, DiscoveryState>(
              builder: (context, state) {
                if (state.status == DiscoveryStatus.loading) {
                  return const SizedBox(height: 36,
                      child: Center(child: CircularProgressIndicator(
                          color: Color(0xFF00D4FF), strokeWidth: 2)));
                }
                final activeDevices = state.devices.where((d) => d.isApproved).toList();
                if (activeDevices.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withOpacity(0.06),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.2)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.info_outline, color: Color(0xFF00D4FF), size: 15),
                      const SizedBox(width: 8),
                      Text(
                        state.devices.isEmpty
                            ? 'No devices discovered yet. Run Discover All Fields first.'
                            : 'No active devices. Approve devices on the Discovery page first.',
                        style: GoogleFonts.poppins(color: const Color(0xFF00D4FF), fontSize: 12)),
                    ]),
                  );
                }
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: activeDevices.map((d) {
                      final sel = _selected?.deviceId == d.deviceId;
                      return GestureDetector(
                        onTap: () => _selectDevice(d),
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: sel
                                ? const Color(0xFF00D4FF).withOpacity(0.12)
                                : Colors.transparent,
                            border: Border.all(
                                color: sel
                                    ? const Color(0xFF00D4FF)
                                    : const Color(0xFF00D4FF).withOpacity(0.25)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 7, height: 7,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF39FF14),
                                )),
                            const SizedBox(width: 8),
                            Text(d.displayName,
                                style: GoogleFonts.poppins(
                                  color: sel ? const Color(0xFF00D4FF) : Colors.white60,
                                  fontSize: 12,
                                  fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                                )),
                          ]),
                        ),
                      );
                    }).toList(),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 10),

          // ── Streaming status bar ─────────────────────────────────────────
          if (_selected != null && _streamCubit != null)
            BlocBuilder<LiveStreamCubit, LiveStreamState>(
              bloc: _streamCubit,
              buildWhen: (p, n) => p.isLoading != n.isLoading || p.lastUpdate != n.lastUpdate,
              builder: (context, state) {
                // Stale = no successful poll within the last 1 minute (matches row-level logic)
                final isStale = state.lastUpdate == null ||
                    DateTime.now().difference(state.lastUpdate!).inMinutes >= 1;
                final dot = isStale ? Colors.redAccent : const Color(0xFF39FF14);
                final msg = isStale ? 'Stale — no data in last 1 min' : 'Active — streaming live';
                final updateStr = state.lastUpdate != null
                    ? state.lastUpdate!.toLocal().toString().substring(11, 19)
                    : '—';
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF010C20),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.15)),
                  ),
                  child: Row(children: [
                    Container(width: 7, height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, color: dot,
                          boxShadow: [BoxShadow(color: dot.withOpacity(0.5), blurRadius: 4)],
                        )),
                    const SizedBox(width: 10),
                    Text(msg, style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12)),
                    if (state.isLoading) ...[
                      const SizedBox(width: 12),
                      const SizedBox(width: 12, height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Color(0xFF00D4FF))),
                    ],
                    const Spacer(),
                    Text('Last update: $updateStr',
                        style: GoogleFonts.poppins(color: Colors.white24, fontSize: 11)),
                  ]),
                );
              },
            )
          else
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF010C20),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.15)),
              ),
              child: Row(children: [
                Container(width: 7, height: 7,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: Colors.white24,
                        boxShadow: [BoxShadow(color: Colors.white24.withOpacity(0.5), blurRadius: 4)])),
                const SizedBox(width: 10),
                Text('Select a device to begin streaming.',
                    style: GoogleFonts.poppins(color: Colors.white38, fontSize: 12)),
              ]),
            ),

          const SizedBox(height: 10),

          // ── Search bar + Measurement filter ─────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _searchCtrl,
                    style: GoogleFonts.poppins(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'Search by display name, tag name or field…',
                      hintStyle: GoogleFonts.poppins(color: Colors.white24, fontSize: 12),
                      prefixIcon: const Icon(Icons.search, color: Colors.white38, size: 16),
                      contentPadding: EdgeInsets.zero,
                      filled: true, fillColor: const Color(0xFF010C20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.2))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.2))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFF00D4FF))),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
                  ),
                ),
              ),
              if (_selected != null) ...[
                const SizedBox(width: 10),
                _MeasurementFilter(
                  device: _selected!,
                  value: _measurementFilter,
                  onChanged: (v) => setState(() => _measurementFilter = v),
                ),
              ],
            ]),
          ),

          const SizedBox(height: 8),
          const Divider(color: Color(0xFF00D4FF), height: 1, thickness: 0.2),

          // ── Table ────────────────────────────────────────────────────────
          if (_selected == null || _streamCubit == null)
            Expanded(child: Center(
              child: Text('No device selected.',
                  style: GoogleFonts.poppins(color: Colors.white24, fontSize: 13)),
            ))
          else
            Expanded(child: _StreamTable(
                device: _selected!, cubit: _streamCubit!, searchQuery: _searchQuery,
                measurementFilter: _measurementFilter)),
        ],
      ),
    );
  }
}

// ── Stream Table ──────────────────────────────────────────────────────────────

/// Dropdown of the distinct real measurements this device's tags come from —
/// e.g. PSTR_bar / PSTR_psi / PSTR_temp for a sterilizer — so the table can
/// be narrowed to one at a time. Hidden when a device only has one (or none
/// reported), since there's nothing to disambiguate.
class _MeasurementFilter extends StatelessWidget {
  final DiscoveredDevice device;
  final String value;
  final ValueChanged<String> onChanged;
  const _MeasurementFilter({required this.device, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final measurements = device.tags.map((t) => t.realMeasurement).where((m) => m.isNotEmpty).toSet().toList()..sort();
    if (measurements.length < 2) return const SizedBox.shrink();
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF010C20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.2)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value.isEmpty ? '' : value,
          isDense: true,
          dropdownColor: const Color(0xFF010C20),
          style: GoogleFonts.poppins(color: Colors.white, fontSize: 12),
          icon: const Icon(Icons.filter_alt_outlined, color: Colors.white38, size: 16),
          items: [
            DropdownMenuItem(value: '', child: Text('All measurements', style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12))),
            for (final m in measurements) DropdownMenuItem(value: m, child: Text(m, style: GoogleFonts.poppins(fontSize: 12))),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }
}

class _StreamTable extends StatefulWidget {
  final DiscoveredDevice device;
  final LiveStreamCubit cubit;
  final String searchQuery;
  final String measurementFilter;
  const _StreamTable(
      {required this.device, required this.cubit, required this.searchQuery,
      this.measurementFilter = ''});

  @override
  State<_StreamTable> createState() => _StreamTableState();
}

class _StreamTableState extends State<_StreamTable> {
  int _page = 0;
  int _perPage = 10;
  // tag key ("<realMeasurement>|<fieldName>") → {tagNameCtrl, unitCtrl}.
  // Keyed on the pair, not fieldName alone — the same field name can exist
  // under several real measurements for one device, and keying on field
  // name alone would make editing one row edit all of them at once.
  final Map<String, Map<String, TextEditingController>> _editControllers = {};
  final Set<String> _editingFields = {};

  String _keyOf(InfluxTag tag) => '${tag.realMeasurement}|${tag.fieldName}';

  void _startEdit(InfluxTag tag) {
    _editControllers[_keyOf(tag)] = {
      'name': TextEditingController(text: tag.tagName.isNotEmpty ? tag.tagName : tag.fieldName),
      'unit': TextEditingController(text: tag.unit),
    };
    setState(() => _editingFields.add(_keyOf(tag)));
  }

  void _cancelEdit(InfluxTag tag) {
    final key = _keyOf(tag);
    _editControllers[key]?['name']?.dispose();
    _editControllers[key]?['unit']?.dispose();
    _editControllers.remove(key);
    setState(() => _editingFields.remove(key));
  }

  void _saveEdit(BuildContext context, InfluxTag tag) {
    final ctrls = _editControllers[_keyOf(tag)];
    if (ctrls == null) return;
    final newName = ctrls['name']!.text.trim();
    final newUnit = ctrls['unit']!.text.trim();
    context.read<DiscoveryCubit>().updateTagMeta(
      widget.device.deviceId, tag.fieldName,
      tagName: newName.isNotEmpty ? newName : tag.fieldName,
      unit: newUnit,
      realMeasurement: tag.realMeasurement,
    );
    _cancelEdit(tag);
  }

  @override
  void dispose() {
    for (final m in _editControllers.values) {
      m['name']?.dispose();
      m['unit']?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LiveStreamCubit, LiveStreamState>(
      bloc: widget.cubit,
      builder: (context, state) {
        final allTags = widget.device.tags.where((t) {
          final matchesSearch = widget.searchQuery.isEmpty ||
              t.tagName.toLowerCase().contains(widget.searchQuery) ||
              t.fieldName.toLowerCase().contains(widget.searchQuery);
          final matchesMeasurement = widget.measurementFilter.isEmpty ||
              t.realMeasurement == widget.measurementFilter;
          return matchesSearch && matchesMeasurement;
        }).toList();

        final totalPages = allTags.isEmpty ? 1 : (allTags.length / _perPage).ceil();
        if (_page >= totalPages) _page = totalPages - 1;
        final pageTags = allTags.skip(_page * _perPage).take(_perPage).toList();

        return Column(
          children: [
            // ── Table header ─────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 7),
              color: const Color(0xFF00D4FF).withOpacity(0.06),
              child: Row(children: [
                const _TH('No.', flex: 1),
                const _TH('Site ID', flex: 3),
                const _TH('Tag Name', flex: 3),
                const _TH('Channel (field)', flex: 3),
                const _TH('Measurement', flex: 2),
                const _TH('Unit', flex: 1),
                const _TH('Status', flex: 2),
                const _TH('Last Update', flex: 3),
                const _TH('Value', flex: 2),
                // Action header — fixed width to match 6 icons
                SizedBox(
                  width: 158,
                  child: Row(children: [
                    if (state.isLoading)
                      const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Color(0xFF39FF14))),
                    const SizedBox(width: 4),
                    Text('Action',
                        style: GoogleFonts.poppins(
                            color: const Color(0xFF00D4FF),
                            fontSize: 10, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ]),
            ),
            const Divider(color: Color(0xFF00D4FF), height: 1, thickness: 0.25),

            // ── Rows ─────────────────────────────────────────────────────
            Expanded(
              child: ListView.builder(
                itemCount: pageTags.length,
                itemBuilder: (context, i) {
                  final globalIndex = _page * _perPage + i;
                  final tag = pageTags[i];
                  final key = '${tag.measurement}.${tag.realMeasurement}.${tag.fieldName}';
                  final value = state.values[key];
                  final isStale = state.isStale(key);
                  final updateStr = state.lastUpdate != null
                      ? state.lastUpdate!.toLocal().toString().substring(11, 19)
                      : '—';

                  final isEditing = _editingFields.contains(_keyOf(tag));
                  final ctrls = _editControllers[_keyOf(tag)];

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
                    decoration: BoxDecoration(
                      color: isEditing
                          ? const Color(0xFF010C20)
                          : Colors.transparent,
                      border: Border(bottom: BorderSide(
                          color: const Color(0xFF00D4FF).withOpacity(0.07))),
                    ),
                    child: Row(children: [
                      // No.
                      Expanded(flex: 1, child: Text('${globalIndex + 1}',
                          style: GoogleFonts.poppins(color: Colors.white24, fontSize: 12))),
                      // Site ID — the Influx `id` tag (full device id, e.g.
                      // SAMYSK_POM_240004), matching the id → _measurement →
                      // _field structure in InfluxDB's own explorer.
                      Expanded(flex: 3, child: Text(widget.device.deviceId,
                          style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),
                      // Tag Name (editable)
                      Expanded(flex: 3, child: isEditing
                          ? _EditField(ctrl: ctrls!['name']!, hint: 'Tag name')
                          : Text(tag.tagName.isNotEmpty ? tag.tagName : tag.fieldName,
                              style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12))),
                      // Channel (field) — always read-only
                      Expanded(flex: 3, child: Text(tag.fieldName,
                          style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11))),
                      // Measurement — the real Influx measurement (e.g. "PSTR_bar"),
                      // not tag.measurement, which is actually this row's device id.
                      Expanded(flex: 2, child: Text(tag.realMeasurement.isEmpty ? '—' : tag.realMeasurement,
                          style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),
                      // Unit (editable)
                      Expanded(flex: 1, child: isEditing
                          ? _EditField(ctrl: ctrls!['unit']!, hint: 'Unit')
                          : Text(tag.unit,
                              style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11))),
                      // Status pill
                      Expanded(flex: 2, child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: isStale ? Colors.redAccent : const Color(0xFF39FF14),
                                width: 1.0),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 6, height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isStale ? Colors.redAccent : const Color(0xFF39FF14),
                                  boxShadow: [BoxShadow(
                                    color: (isStale ? Colors.redAccent : const Color(0xFF39FF14))
                                        .withOpacity(0.5),
                                    blurRadius: 4)],
                                )),
                            const SizedBox(width: 5),
                            Text(isStale ? 'Stale' : 'Live',
                                style: GoogleFonts.poppins(
                                    color: isStale ? Colors.redAccent : const Color(0xFF39FF14),
                                    fontSize: 10, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      )),
                      // Last Update
                      Expanded(flex: 3, child: Text(updateStr,
                          style: GoogleFonts.poppins(color: Colors.white24, fontSize: 11))),
                      // Value
                      Expanded(flex: 2, child: Text(
                          value != null ? value.toString() : '—',
                          style: GoogleFonts.poppins(
                              color: const Color(0xFF39FF14),
                              fontWeight: FontWeight.bold, fontSize: 13),
                          textAlign: TextAlign.right)),
                      // Action icons
                      SizedBox(
                        width: 158,
                        child: isEditing
                            ? Row(mainAxisSize: MainAxisSize.min, children: [
                                const SizedBox(width: 8),
                                _IBtn(Icons.check, const Color(0xFF39FF14), 'Save',
                                    () => _saveEdit(context, tag)),
                                _IBtn(Icons.close, Colors.white38, 'Cancel',
                                    () => _cancelEdit(tag)),
                              ])
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                const SizedBox(width: 8),
                                // 1. Reconnect — targeted re-fetch for this tag
                                state.reconnectingKeys.contains('${tag.measurement}.${tag.realMeasurement}.${tag.fieldName}')
                                    ? const Padding(
                                        padding: EdgeInsets.all(4),
                                        child: SizedBox(width: 14, height: 14,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 1.5, color: Color(0xFF39FF14))),
                                      )
                                    : _IBtn(Icons.system_update_alt, const Color(0xFF39FF14), 'Reconnect',
                                        () => widget.cubit.reconnectTag(tag)),
                                // 2. Raw Query
                                _IBtn(Icons.code, const Color(0xFF4488FF), 'Raw Query', () {
                                  showDialog(context: context,
                                      builder: (_) => _RawQueryTagDialog(
                                        deviceId: widget.device.deviceId,
                                        fieldName: tag.fieldName,
                                      ));
                                }),
                                // 3. Threshold (placeholder)
                                _IBtn(Icons.notifications_outlined, Colors.orange, 'Threshold', () {}),
                                // 4. Edit
                                _IBtn(Icons.edit_outlined, Colors.white38, 'Edit',
                                    () => _startEdit(tag)),
                                // 5. History
                                _IBtn(Icons.bar_chart_outlined, const Color(0xFF00D4FF), 'History', () {
                                  showDialog(context: context,
                                      builder: (_) => _HistoryDialog(
                                        deviceId: widget.device.deviceId,
                                        fieldName: tag.fieldName,
                                        unit: tag.unit,
                                        tagName: tag.tagName.isNotEmpty ? tag.tagName : tag.fieldName,
                                        realMeasurement: tag.realMeasurement,
                                      ));
                                }),
                                // 6. Delete
                                _IBtn(Icons.delete_outline, Colors.redAccent, 'Remove', () {}),
                              ]),
                      ),
                    ]),
                  );
                },
              ),
            ),

            // ── Pagination footer ─────────────────────────────────────────
            _PaginationFooter(
              total: allTags.length,
              page: _page,
              perPage: _perPage,
              totalPages: totalPages,
              onPerPageChanged: (v) => setState(() { _perPage = v; _page = 0; }),
              onPageChanged: (p) => setState(() => _page = p),
            ),
          ],
        );
      },
    );
  }
}

// ── Inline edit field ─────────────────────────────────────────────────────────

class _EditField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  const _EditField({required this.ctrl, required this.hint});

  @override
  Widget build(BuildContext context) => TextField(
        controller: ctrl,
        style: GoogleFonts.poppins(color: Colors.white, fontSize: 11),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.poppins(color: Colors.white24, fontSize: 11),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          filled: true,
          fillColor: const Color(0xFF020B2D),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xFF00D4FF))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xFF00D4FF), width: 1.5)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.4))),
        ),
      );
}

// ── History Dialog ────────────────────────────────────────────────────────────

class _HistoryDialog extends StatefulWidget {
  final String deviceId;
  final String fieldName;
  final String unit;
  final String tagName;
  final String realMeasurement;
  const _HistoryDialog({
    required this.deviceId, required this.fieldName,
    required this.unit, required this.tagName,
    this.realMeasurement = '',
  });

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  final _svc = InfluxDiscoveryService();
  List<HistoryPoint> _points = [];
  bool _loading = true;
  String _range = '-1h';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final pts = await _svc.fetchFieldHistory(
        widget.deviceId, widget.fieldName, range: _range, realMeasurement: widget.realMeasurement);
    if (mounted) setState(() { _points = pts; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final minY = _points.isEmpty ? 0.0 : _points.map((p) => p.value).reduce((a, b) => a < b ? a : b);
    final maxY = _points.isEmpty ? 1.0 : _points.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final yPad = (maxY - minY) * 0.1 == 0 ? 1.0 : (maxY - minY) * 0.1;

    return Dialog(
      backgroundColor: const Color(0xFF010C20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.4)),
      ),
      child: Container(
        width: responsiveDialogWidth(context, 680),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(children: [
              const Icon(Icons.bar_chart_outlined, color: Color(0xFF00D4FF), size: 16),
              const SizedBox(width: 8),
              Text('History / Trends',
                  style: GoogleFonts.outfit(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text('— ${widget.tagName}',
                  style: GoogleFonts.poppins(color: Colors.white38, fontSize: 12)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: const Icon(Icons.close, color: Colors.white38, size: 18),
              ),
            ]),
            const SizedBox(height: 4),
            Text('Device: ${widget.deviceId}  •  Field: ${widget.fieldName}'
                '${widget.unit.isNotEmpty ? "  •  Unit: ${widget.unit}" : ""}',
                style: GoogleFonts.poppins(color: Colors.white24, fontSize: 10)),
            const SizedBox(height: 12),

            // Range selector
            Row(children: [
              Text('Range:', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11)),
              const SizedBox(width: 8),
              ...{'-30m': '30 min', '-1h': '1 hour', '-6h': '6 hours', '-24h': '24 hours'}
                  .entries.map((e) {
                final active = _range == e.key;
                return GestureDetector(
                  onTap: () { _range = e.key; _load(); },
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: active ? const Color(0xFF00D4FF).withOpacity(0.12) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: active ? const Color(0xFF00D4FF) : Colors.white24, width: 0.8),
                    ),
                    child: Text(e.value,
                        style: GoogleFonts.poppins(
                            color: active ? const Color(0xFF00D4FF) : Colors.white38,
                            fontSize: 11,
                            fontWeight: active ? FontWeight.bold : FontWeight.normal)),
                  ),
                );
              }),
              if (_loading) ...[
                const SizedBox(width: 8),
                const SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF00D4FF))),
              ],
            ]),
            const SizedBox(height: 16),

            // Chart
            SizedBox(
              height: 260,
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF)))
                  : _points.isEmpty
                      ? Center(child: Text('No historical data available.',
                            style: GoogleFonts.poppins(color: Colors.white38, fontSize: 12)))
                      : LineChart(
                          LineChartData(
                            backgroundColor: const Color(0xFF020B2D),
                            minY: minY - yPad,
                            maxY: maxY + yPad,
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: true,
                              getDrawingHorizontalLine: (_) => FlLine(
                                  color: const Color(0xFF00D4FF).withOpacity(0.08),
                                  strokeWidth: 0.8),
                              getDrawingVerticalLine: (_) => FlLine(
                                  color: const Color(0xFF00D4FF).withOpacity(0.05),
                                  strokeWidth: 0.5),
                            ),
                            borderData: FlBorderData(
                              show: true,
                              border: Border.all(
                                  color: const Color(0xFF00D4FF).withOpacity(0.2), width: 0.8),
                            ),
                            titlesData: FlTitlesData(
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 46,
                                  getTitlesWidget: (v, _) => Text(
                                      v.toStringAsFixed(1),
                                      style: GoogleFonts.poppins(
                                          color: Colors.white24, fontSize: 9)),
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 22,
                                  interval: _points.length > 1
                                      ? (_points.last.time.millisecondsSinceEpoch -
                                              _points.first.time.millisecondsSinceEpoch) /
                                          4.0
                                      : 1,
                                  getTitlesWidget: (v, _) {
                                    final t = DateTime.fromMillisecondsSinceEpoch(v.toInt());
                                    return Text(
                                        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                                        style: GoogleFonts.poppins(
                                            color: Colors.white24, fontSize: 9));
                                  },
                                ),
                              ),
                              rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                            ),
                            lineTouchData: LineTouchData(
                              touchTooltipData: LineTouchTooltipData(
                                getTooltipItems: (spots) => spots.map((s) =>
                                    LineTooltipItem(
                                      '${s.y.toStringAsFixed(2)} ${widget.unit}',
                                      GoogleFonts.poppins(
                                          color: const Color(0xFF39FF14), fontSize: 11),
                                    )).toList(),
                              ),
                            ),
                            lineBarsData: [
                              LineChartBarData(
                                spots: _points.map((p) => FlSpot(
                                    p.time.millisecondsSinceEpoch.toDouble(),
                                    p.value)).toList(),
                                isCurved: true,
                                color: const Color(0xFF00D4FF),
                                barWidth: 1.8,
                                dotData: const FlDotData(show: false),
                                belowBarData: BarAreaData(
                                  show: true,
                                  color: const Color(0xFF00D4FF).withOpacity(0.07),
                                ),
                              ),
                            ],
                          ),
                        ),
            ),

            // Summary row
            if (!_loading && _points.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                _StatChip('Min', _points.map((p) => p.value).reduce((a, b) => a < b ? a : b)
                    .toStringAsFixed(2), Colors.white38),
                const SizedBox(width: 8),
                _StatChip('Max', _points.map((p) => p.value).reduce((a, b) => a > b ? a : b)
                    .toStringAsFixed(2), const Color(0xFF39FF14)),
                const SizedBox(width: 8),
                _StatChip('Avg',
                    (_points.map((p) => p.value).reduce((a, b) => a + b) / _points.length)
                        .toStringAsFixed(2),
                    const Color(0xFF00D4FF)),
                const SizedBox(width: 8),
                _StatChip('Points', '${_points.length}', Colors.white24),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.3), width: 0.8),
        ),
        child: RichText(
          text: TextSpan(children: [
            TextSpan(text: '$label: ',
                style: GoogleFonts.poppins(color: Colors.white38, fontSize: 10)),
            TextSpan(text: value,
                style: GoogleFonts.poppins(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
          ]),
        ),
      );
}

// ── Raw Query Dialog (tag-level) ──────────────────────────────────────────────

class _RawQueryTagDialog extends StatelessWidget {
  final String deviceId;
  final String fieldName;
  const _RawQueryTagDialog(
      {required this.deviceId, required this.fieldName});

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: const Color(0xFF010C20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: const Color(0xFF4488FF).withOpacity(0.5)),
        ),
        child: Container(
          width: responsiveDialogWidth(context, 560),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.code, color: Color(0xFF4488FF), size: 16),
                const SizedBox(width: 8),
                Text('Raw Flux Query',
                    style: GoogleFonts.outfit(
                        color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close, color: Colors.white38, size: 18),
                ),
              ]),
              const SizedBox(height: 6),
              Text('Device: $deviceId  •  Field: $fieldName',
                  style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF020B2D),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF4488FF).withOpacity(0.25)),
                ),
                child: Text(
                  'from(bucket: "ENERGY_DEMO")\n'
                  '  |> range(start: -5m)\n'
                  '  |> filter(fn: (r) => r["_measurement"] == "power_meter")\n'
                  '  |> filter(fn: (r) => r["device_id"] == "$deviceId")\n'
                  '  |> filter(fn: (r) => r["_field"] == "$fieldName")\n'
                  '  |> last()',
                  style: GoogleFonts.poppins(
                      color: const Color(0xFF00D4FF), fontSize: 11, height: 1.6),
                ),
              ),
            ],
          ),
        ),
      );
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _IBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _IBtn(this.icon, this.color, this.tooltip, this.onTap);
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(icon, color: color, size: 16)),
        ),
      );
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 0.5),
          borderRadius: BorderRadius.circular(10),
          color: color.withOpacity(0.1),
        ),
        child: Text(text, style: GoogleFonts.poppins(color: color, fontSize: 10)),
      );
}

class _TBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _TBtn(this.label, this.icon, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 0.8),
            borderRadius: BorderRadius.circular(8),
            color: color.withOpacity(0.07),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(label,
                style: GoogleFonts.poppins(
                    color: color, fontSize: 12, fontWeight: FontWeight.w500)),
          ]),
        ),
      );
}

class _TH extends StatelessWidget {
  final String text;
  final int flex;
  const _TH(this.text, {required this.flex});
  @override
  Widget build(BuildContext context) => Expanded(
        flex: flex,
        child: Text(text,
            style: GoogleFonts.poppins(
                color: const Color(0xFF00D4FF),
                fontSize: 10, fontWeight: FontWeight.bold)),
      );
}

class _PaginationFooter extends StatelessWidget {
  final int total, page, perPage, totalPages;
  final ValueChanged<int> onPerPageChanged;
  final ValueChanged<int> onPageChanged;

  const _PaginationFooter({
    required this.total, required this.page, required this.perPage,
    required this.totalPages, required this.onPerPageChanged,
    required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    final from = total == 0 ? 0 : page * perPage + 1;
    final to = ((page + 1) * perPage).clamp(0, total);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF010C20),
        border: Border(top: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.15))),
      ),
      child: Row(children: [
        Text('Showing $from–$to of $total',
            style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11)),
        const SizedBox(width: 16),
        Text('Rows:', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11)),
        const SizedBox(width: 6),
        DropdownButton<int>(
          value: perPage,
          dropdownColor: const Color(0xFF010C20),
          underline: const SizedBox.shrink(),
          style: const TextStyle(color: Color(0xFF00D4FF), fontSize: 11),
          items: [5, 10, 20, 50].map((v) =>
              DropdownMenuItem(value: v, child: Text('$v'))).toList(),
          onChanged: (v) { if (v != null) onPerPageChanged(v); },
        ),
        const Spacer(),
        _PageBtn(Icons.chevron_left, page > 0, () => onPageChanged(page - 1)),
        const SizedBox(width: 4),
        ...List.generate(totalPages, (i) {
          final active = i == page;
          return GestureDetector(
            onTap: () => onPageChanged(i),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: active ? const Color(0xFF00D4FF).withOpacity(0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: active ? const Color(0xFF00D4FF) : Colors.white12, width: 0.8),
              ),
              child: Center(child: Text('${i + 1}',
                  style: GoogleFonts.poppins(
                      color: active ? const Color(0xFF00D4FF) : Colors.white38,
                      fontSize: 11,
                      fontWeight: active ? FontWeight.bold : FontWeight.normal))),
            ),
          );
        }),
        const SizedBox(width: 4),
        _PageBtn(Icons.chevron_right, page < totalPages - 1, () => onPageChanged(page + 1)),
      ]),
    );
  }
}

class _PageBtn extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _PageBtn(this.icon, this.enabled, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: enabled ? Colors.white24 : Colors.white12, width: 0.7),
          ),
          child: Icon(icon, size: 16,
              color: enabled ? const Color(0xFF00D4FF) : Colors.white12),
        ),
      );
}
