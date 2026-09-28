import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '../cubits/discovery_cubit.dart';
import '../models/discovery_models.dart';
import 'expansion_details_widget.dart';

class DiscoveryTable extends StatefulWidget {
  final String searchQuery;
  const DiscoveryTable({super.key, this.searchQuery = ''});

  @override
  State<DiscoveryTable> createState() => _DiscoveryTableState();
}

class _DiscoveryTableState extends State<DiscoveryTable> {
  int _page = 0;
  int _perPage = 10;
  final ScrollController _hScroll = ScrollController();
  double _hOffset = 0;

  @override
  void initState() {
    super.initState();
    _hScroll.addListener(() {
      // Use the first attached position to track current offset
      if (_hScroll.hasClients) {
        _hOffset = _hScroll.positions.first.pixels;
      }
    });
  }

  void _scrollBy(double delta) {
    if (!_hScroll.hasClients) return;
    final maxExtent = _hScroll.positions.fold<double>(
      0, (max, p) => p.maxScrollExtent > max ? p.maxScrollExtent : max,
    );
    final target = (_hOffset + delta).clamp(0.0, maxExtent);
    for (final pos in _hScroll.positions) {
      pos.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        if (state.status == DiscoveryStatus.loading) {
          return const Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF)));
        }
        final all = widget.searchQuery.isEmpty
            ? state.devices
            : state.devices.where((d) =>
                d.displayName.toLowerCase().contains(widget.searchQuery) ||
                d.deviceId.toLowerCase().contains(widget.searchQuery) ||
                d.plantName.toLowerCase().contains(widget.searchQuery)).toList();

        if (all.isEmpty) {
          return Center(
              child: Text('No devices found.',
                  style: GoogleFonts.poppins(color: Colors.white38, fontSize: 13)));
        }

        final totalPages = (all.length / _perPage).ceil();
        if (_page >= totalPages) _page = totalPages - 1;
        final pageItems = all.skip(_page * _perPage).take(_perPage).toList();

        return Column(
          children: [
            // Column headers + pinned scroll buttons
            Stack(
              children: [
                SingleChildScrollView(
                  controller: _hScroll,
                  scrollDirection: Axis.horizontal,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    color: const Color(0xFF00D4FF).withOpacity(0.06),
                    child: Row(children: [
                      const SizedBox(width: 20),
                      _HW('Display Name', width: 130),
                      _HW('Device Type', width: 140),
                      _HW('Device ID [M]', width: 110),
                      _HW('Device Name', width: 120),
                      _HW('Site', width: 160),
                      _HW('Site ID', width: 90),
                      _HW('Machine ID', width: 100),
                      _HW('Machine Name', width: 130),
                      _HW('Line ID', width: 90),
                      _HW('Line Name', width: 120),
                      _HW('Zone ID', width: 90),
                      _HW('Zone Name', width: 130),
                      _HW('Parent ID', width: 100),
                      _HW('Parent Name', width: 130),
                      _HW('Status', width: 100),
                      _HW('Channels (_field)', width: 120),
                      _HW('Actions', width: 160),
                    ]),
                  ),
                ),
                // Scroll buttons pinned to right edge of header
                Positioned(
                  right: 8,
                  top: 0,
                  bottom: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ScrollBtn(Icons.chevron_left,  'Scroll left',  () => _scrollBy(-300)),
                      const SizedBox(width: 4),
                      _ScrollBtn(Icons.chevron_right, 'Scroll right', () => _scrollBy(300)),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(color: Color(0xFF00D4FF), height: 1, thickness: 0.3),

            // Rows
            Expanded(
              child: ListView.builder(
                itemCount: pageItems.length,
                itemBuilder: (context, i) {
                  final d = pageItems[i];
                  final expanded = state.expandedIds.contains(d.deviceId);
                  return _DeviceRow(device: d, isExpanded: expanded, hScroll: _hScroll);
                },
              ),
            ),

            // Pagination footer
            _PaginationFooter(
              total: all.length,
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

// ── Row ───────────────────────────────────────────────────────────────────────

class _DeviceRow extends StatefulWidget {
  final DiscoveredDevice device;
  final bool isExpanded;
  final ScrollController hScroll;
  const _DeviceRow({required this.device, required this.isExpanded, required this.hScroll});

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  bool _editing = false;
  late TextEditingController _nameCtrl;
  late bool _statusActive;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.device.displayName);
    _statusActive = widget.device.isApproved;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DiscoveryCubit>();

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: widget.isExpanded ? const Color(0xFF010C20) : Colors.transparent,
            border: Border(bottom: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.08))),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: SingleChildScrollView(
            controller: widget.hScroll,
            scrollDirection: Axis.horizontal,
            child: Row(children: [
            // Status dot
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _statusActive ? const Color(0xFF39FF14) : Colors.orange,
                boxShadow: [BoxShadow(
                  color: (_statusActive ? const Color(0xFF39FF14) : Colors.orange).withOpacity(0.5),
                  blurRadius: 5)],
              ),
            ),
            const SizedBox(width: 12),

            // Display Name (editable) — 130
            SizedBox(width: 130, child: _editing
                ? TextField(
                    controller: _nameCtrl,
                    style: GoogleFonts.poppins(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      filled: true, fillColor: const Color(0xFF010820),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Color(0xFF00D4FF))),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Color(0xFF00D4FF), width: 1.5)),
                    ),
                  )
                : Text(widget.device.displayName,
                    style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12))),

            // Device Type (dynamic dropdown from API) — 140
            SizedBox(width: 140, child: Container(
              height: 30,
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF010C20),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.3)),
              ),
              child: DropdownButtonHideUnderline(
                child: BlocBuilder<DiscoveryCubit, DiscoveryState>(
                  buildWhen: (p, n) => p.deviceTypes != n.deviceTypes,
                  builder: (context, state) {
                    final options = state.deviceTypes;
                    return DropdownButton<String>(
                      value: options.contains(widget.device.deviceType)
                          ? widget.device.deviceType
                          : null,
                      hint: Text('— Select —', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 10)),
                      dropdownColor: const Color(0xFF020B2D),
                      isDense: true,
                      isExpanded: true,
                      icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF00D4FF), size: 18),
                      style: GoogleFonts.poppins(fontSize: 11, color: Colors.white),
                      items: options.map((t) => DropdownMenuItem(
                        value: t,
                        child: Text(t, style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11)),
                      )).toList(),
                      onChanged: (v) async {
                        if (v != null) await context.read<DiscoveryCubit>().changeDeviceType(widget.device.deviceId, v);
                      },
                    );
                  },
                ),
              ),
            )),

            // Device ID [M] — 110
            SizedBox(width: 110, child: Text(widget.device.deviceId,
                style: GoogleFonts.poppins(color: const Color(0xFF00D4FF), fontSize: 11))),

            // Device Name — 120
            SizedBox(width: 120, child: Text(widget.device.deviceName,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Site — 160
            SizedBox(width: 160, child: Text(widget.device.plantName,
                style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11))),

            // Site ID — 90
            SizedBox(width: 90, child: Text(widget.device.siteId,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Machine ID — 100
            SizedBox(width: 100, child: Text(widget.device.machineId,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Machine Name — 130
            SizedBox(width: 130, child: Text(widget.device.machineName,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Line ID — 90
            SizedBox(width: 90, child: Text(widget.device.lineId,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Line Name — 120
            SizedBox(width: 120, child: Text(widget.device.lineName,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Zone ID — 90
            SizedBox(width: 90, child: Text(widget.device.zoneId,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Zone Name — 130
            SizedBox(width: 130, child: Text(widget.device.zoneName,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Parent ID — 100
            SizedBox(width: 100, child: Text(widget.device.parentId,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Parent Name — 130
            SizedBox(width: 130, child: Text(widget.device.parentName,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11))),

            // Status (editable dropdown) — 100
            SizedBox(width: 100, child: _editing
                ? DropdownButton<bool>(
                    value: _statusActive,
                    dropdownColor: const Color(0xFF010C20),
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    style: GoogleFonts.poppins(fontSize: 11),
                    items: [
                      DropdownMenuItem(value: true,
                          child: Text('Active', style: GoogleFonts.poppins(color: const Color(0xFF39FF14), fontSize: 11))),
                      DropdownMenuItem(value: false,
                          child: Text('Inactive', style: GoogleFonts.poppins(color: Colors.orange, fontSize: 11))),
                    ],
                    onChanged: (v) { if (v != null) setState(() => _statusActive = v); },
                  )
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: _statusActive ? const Color(0xFF39FF14) : Colors.orange,
                            width: 1.0),
                      ),
                      child: Text(_statusActive ? 'Active' : 'Inactive',
                          style: GoogleFonts.poppins(
                              color: _statusActive ? const Color(0xFF39FF14) : Colors.orange,
                              fontSize: 10, fontWeight: FontWeight.w600),
                          textAlign: TextAlign.center),
                    ),
                  )),

            // Channels (_field) count — 120
            SizedBox(width: 120, child: Text('${widget.device.tags.length} fields',
                style: GoogleFonts.poppins(color: const Color(0xFF00D4FF), fontSize: 11))),

            // Actions — 160
            SizedBox(
              width: 160,
              child: _editing
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      _IBtn(Icons.check, const Color(0xFF39FF14), 'Save', () async {
                        final newName = _nameCtrl.text.trim();
                        if (newName.isNotEmpty) await cubit.rename(widget.device.deviceId, newName);
                        if (_statusActive != widget.device.isApproved) {
                          _statusActive
                              ? await cubit.approve(widget.device.deviceId)
                              : await cubit.hide(widget.device.deviceId);
                        }
                        setState(() => _editing = false);
                      }),
                      _IBtn(Icons.close, Colors.white38, 'Cancel', () {
                        setState(() {
                          _editing = false;
                          _nameCtrl.text = widget.device.displayName;
                          _statusActive = widget.device.isApproved;
                        });
                      }),
                    ])
                  : BlocBuilder<DiscoveryCubit, DiscoveryState>(
                      buildWhen: (p, n) =>
                          p.reconnectingIds.contains(widget.device.deviceId) !=
                          n.reconnectingIds.contains(widget.device.deviceId),
                      builder: (context, state) {
                        final isReconnecting = state.reconnectingIds.contains(widget.device.deviceId);
                        return Row(mainAxisSize: MainAxisSize.min, children: [
                          isReconnecting
                              ? const Padding(
                                  padding: EdgeInsets.all(5),
                                  child: SizedBox(width: 14, height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 1.5, color: Color(0xFF39FF14))),
                                )
                              : _IBtn(Icons.system_update_alt, const Color(0xFF39FF14), 'Reconnect',
                                  () => cubit.reconnectDevice(widget.device.deviceId)),
                          _IBtn(Icons.code, const Color(0xFF4488FF), 'Raw Query', () {
                            showDialog(
                              context: context,
                              builder: (_) => _RawQueryDialog(
                                deviceId: widget.device.deviceId,
                                measurement: widget.device.tags.isNotEmpty &&
                                        widget.device.tags.first.realMeasurement.isNotEmpty
                                    ? widget.device.tags.first.realMeasurement
                                    : '<measurement>',
                              ),
                            );
                          }),
                          _IBtn(
                              widget.isExpanded ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              const Color(0xFF00D4FF), 'Live Details',
                              () => cubit.toggleExpand(widget.device.deviceId)),
                          _IBtn(Icons.edit_outlined, Colors.white70, 'Edit',
                              () => setState(() => _editing = true)),
                          _IBtn(Icons.delete_outline, Colors.redAccent, 'Remove',
                              () => cubit.hide(widget.device.deviceId)),
                        ]);
                      },
                    ),
            ),
          ]),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: widget.isExpanded
              ? ExpansionDetailsWidget(device: widget.device)
              : const SizedBox.shrink(),
          crossFadeState: widget.isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 280),
        ),
      ],
    );
  }
}

// ── Pagination Footer ─────────────────────────────────────────────────────────

class _PaginationFooter extends StatelessWidget {
  final int total, page, perPage, totalPages;
  final ValueChanged<int> onPerPageChanged;
  final ValueChanged<int> onPageChanged;

  const _PaginationFooter({
    required this.total, required this.page, required this.perPage,
    required this.totalPages, required this.onPerPageChanged, required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    final from = total == 0 ? 0 : page * perPage + 1;
    final to = ((page + 1) * perPage).clamp(0, total);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
          style: GoogleFonts.poppins(color: const Color(0xFF00D4FF), fontSize: 11),
          items: [5, 10, 20, 50].map((v) => DropdownMenuItem(
            value: v, child: Text('$v'))).toList(),
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
              child: Center(
                child: Text('${i + 1}',
                    style: GoogleFonts.poppins(
                        color: active ? const Color(0xFF00D4FF) : Colors.white38,
                        fontSize: 11, fontWeight: active ? FontWeight.bold : FontWeight.normal)),
              ),
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
            border: Border.all(color: enabled ? Colors.white24 : Colors.white12, width: 0.7),
          ),
          child: Icon(icon,
              size: 16, color: enabled ? const Color(0xFF00D4FF) : Colors.white12),
        ),
      );
}

// ── Raw Query Dialog ──────────────────────────────────────────────────────────

class _RawQueryDialog extends StatelessWidget {
  final String deviceId;
  final String measurement;
  const _RawQueryDialog({required this.deviceId, required this.measurement});

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
                    style: GoogleFonts.outfit(color: Colors.white, fontSize: 15,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close, color: Colors.white38, size: 18),
                ),
              ]),
              const SizedBox(height: 6),
              Text('Device: $deviceId',
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
                  '  |> filter(fn: (r) => r["_measurement"] == "$measurement")\n'
                  '  |> filter(fn: (r) => r["device_id"] == "$deviceId")\n'
                  '  |> filter(fn: (r) => exists r["_field"])\n'
                  '  |> keep(columns: ["device_id","device_name","site_id","_field","_measurement","_value"])\n'
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

// ── Shared helpers ────────────────────────────────────────────────────────────

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
          child: Padding(padding: const EdgeInsets.all(5),
              child: Icon(icon, color: color, size: 17)),
        ),
      );
}

class _ScrollBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ScrollBtn(this.icon, this.tooltip, this.onTap);
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.4), width: 0.8),
            ),
            child: Icon(icon, size: 16, color: const Color(0xFF00D4FF)),
          ),
        ),
      );
}

class _HW extends StatelessWidget {
  final String text;
  final double width;
  const _HW(this.text, {required this.width});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Text(text,
            style: GoogleFonts.poppins(
                color: const Color(0xFF00D4FF), fontSize: 10, fontWeight: FontWeight.bold)),
      );
}
