import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import '/flutter_flow/rbac.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'cubits/discovery_cubit.dart';
import 'widgets/discovery_table.dart';

class RealTimeDiscoveryPage extends StatelessWidget {
  const RealTimeDiscoveryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _DiscoveryPageContent();
  }
}

class _DiscoveryPageContent extends StatefulWidget {
  const _DiscoveryPageContent();
  @override
  State<_DiscoveryPageContent> createState() => _DiscoveryPageContentState();
}

class _DiscoveryPageContentState extends State<_DiscoveryPageContent> {
  bool _autoMode = false;
  String _lastScan = '—';
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
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

  @override
  void dispose() {
    _countdownTimer?.cancel();
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
          // ── Header row: breadcrumb + title (left) / toolbar (right) ─────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dashboard / Real-Time Data Configurator',
                        style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text('Device Discovery',
                        style: GoogleFonts.outfit(
                            color: Colors.white, fontSize: 20,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                const Spacer(),
                // ── Toolbar buttons ────────────────────────────────────────
                BlocBuilder<DiscoveryCubit, DiscoveryState>(
                  buildWhen: (p, n) => p.status != n.status,
                  builder: (context, state) => _TBtn(
                    'Discover All Fields', Icons.radar, const Color(0xFF00D4FF),
                    () {
                      cubit.discoverAll();
                      setState(() => _lastScan = _nowStr());
                    },
                    isLoading: state.status == DiscoveryStatus.loading,
                  ),
                ),
                const SizedBox(width: 8),
                BlocBuilder<DiscoveryCubit, DiscoveryState>(
                  buildWhen: (p, n) => p.isRefreshing != n.isRefreshing,
                  builder: (context, state) => _TBtn(
                    'Discover Now', Icons.refresh,
                    Colors.white60, () {
                      cubit.refreshNow();
                      setState(() => _lastScan = _nowStr());
                    },
                    isLoading: state.isRefreshing,
                  ),
                ),
                const SizedBox(width: 8),
                // Approve All — activates every discovered device for Live
                // Data Insight in one go. Super Admin only: this is a bulk
                // action across the whole device list, not a single row edit.
                if (AppRoles.normalizeRole(AppStateNotifier.instance.userRole ?? '') == AppRoles.superAdmin) ...[
                  BlocBuilder<DiscoveryCubit, DiscoveryState>(
                    buildWhen: (p, n) => p.isApprovingAll != n.isApprovingAll || p.devices != n.devices,
                    builder: (context, state) {
                      final pending = state.devices.where((d) => !d.isApproved).length;
                      return _TBtn(
                        pending == 0 ? 'All Active' : 'Activate All ($pending)',
                        Icons.bolt, const Color(0xFF39FF14),
                        pending == 0 ? () {} : () => cubit.approveAll(),
                        isLoading: state.isApprovingAll,
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                // Show Hidden toggle
                BlocBuilder<DiscoveryCubit, DiscoveryState>(
                  buildWhen: (p, n) => p.showHidden != n.showHidden,
                  builder: (context, state) => GestureDetector(
                    onTap: () => cubit.toggleShowHidden(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: state.showHidden ? Colors.orange : Colors.white24,
                            width: 0.8),
                        borderRadius: BorderRadius.circular(8),
                        color: state.showHidden
                            ? Colors.orange.withOpacity(0.08)
                            : Colors.transparent,
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(state.showHidden ? Icons.visibility : Icons.visibility_off,
                            size: 14,
                            color: state.showHidden ? Colors.orange : Colors.white38),
                        const SizedBox(width: 6),
                        Text(state.showHidden ? 'Showing Hidden' : 'Show Hidden',
                            style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: state.showHidden ? Colors.orange : Colors.white38)),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Restore All
                BlocBuilder<DiscoveryCubit, DiscoveryState>(
                  buildWhen: (p, n) => p.isRestoring != n.isRestoring,
                  builder: (context, state) => _TBtn(
                    'Restore All', Icons.restore, Colors.white38,
                    () => cubit.restoreAll(),
                    isLoading: state.isRestoring,
                  ),
                ),
                const SizedBox(width: 8),
                // Auto toggle
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
                          color: _autoMode ? const Color(0xFF39FF14) : Colors.white24, width: 0.8),
                      borderRadius: BorderRadius.circular(8),
                      color: _autoMode ? const Color(0xFF39FF14).withOpacity(0.08) : Colors.transparent,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timer,
                            size: 14,
                            color: _autoMode ? const Color(0xFF39FF14) : Colors.white38),
                        const SizedBox(width: 6),
                        Text(_autoMode ? 'Auto ON' : 'Auto (1 min)',
                            style: GoogleFonts.poppins(
                                fontSize: 12,
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
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),


          const SizedBox(height: 10),

          // ── Alert Banner ─────────────────────────────────────────────────
          BlocBuilder<DiscoveryCubit, DiscoveryState>(
            buildWhen: (p, n) => p.status != n.status || p.isFromCache != n.isFromCache,
            builder: (context, state) {
              if (state.isFromCache && state.devices.isNotEmpty) {
                return _Banner(
                    icon: Icons.history,
                    msg: 'Showing cached data — devices may no longer exist in InfluxDB. Press Discover to sync.',
                    color: Colors.orange);
              }
              if (state.status == DiscoveryStatus.error) {
                return _Banner(
                    icon: Icons.error_outline,
                    msg: 'Error: ${state.error}',
                    color: Colors.redAccent);
              }
              if (state.status == DiscoveryStatus.loaded && state.devices.isEmpty) {
                return const _Banner(
                    icon: Icons.info_outline,
                    msg: 'No new devices found from InfluxDB scan.',
                    color: Color(0xFF00D4FF));
              }
              return const SizedBox.shrink();
            },
          ),

          // ── Status bar ───────────────────────────────────────────────────
          BlocBuilder<DiscoveryCubit, DiscoveryState>(
            buildWhen: (p, n) =>
                p.status != n.status ||
                p.devices.length != n.devices.length ||
                p.isRefreshing != n.isRefreshing,
            builder: (context, state) {
              String msg;
              Color dot;
              if (state.status == DiscoveryStatus.loading) {
                msg = 'Scanning InfluxDB...';
                dot = Colors.orange;
              } else if (state.isRefreshing) {
                msg = 'Refreshing ${state.devices.length} device(s)...';
                dot = Colors.orange;
              } else if (state.status == DiscoveryStatus.loaded) {
                msg = '${state.devices.length} device(s) discovered';
                dot = const Color(0xFF39FF14);
              } else {
                msg = 'Ready — press Discover to start.';
                dot = Colors.white24;
              }
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFF010C20),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.15)),
                ),
                child: Row(
                  children: [
                    Container(width: 7, height: 7,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: dot,
                            boxShadow: [BoxShadow(color: dot.withOpacity(0.5), blurRadius: 4)])),
                    const SizedBox(width: 10),
                    Text(msg, style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12)),
                    if (state.status == DiscoveryStatus.loading || state.isRefreshing) ...[
                      const SizedBox(width: 12),
                      const SizedBox(width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF00D4FF))),
                    ],
                    const Spacer(),
                    Text('Last scan: $_lastScan',
                        style: GoogleFonts.poppins(color: Colors.white24, fontSize: 11)),
                  ],
                ),
              );
            },
          ),

          const SizedBox(height: 10),

          // ── Search bar ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _searchCtrl,
                style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search by display name, device ID or plant…',
                  hintStyle: GoogleFonts.poppins(color: Colors.white24, fontSize: 12),
                  prefixIcon: const Icon(Icons.search, color: Colors.white38, size: 18),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                  filled: true,
                  fillColor: const Color(0xFF010C20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.2)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.2)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF00D4FF)),
                  ),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ── Table ────────────────────────────────────────────────────────
          Expanded(child: DiscoveryTable(searchQuery: _searchQuery)),
        ],
      ),
    );
  }

  String _nowStr() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }
}

class _TBtn extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool isLoading;
  const _TBtn(this.label, this.icon, this.color, this.onTap,
      {this.isLoading = false});

  @override
  State<_TBtn> createState() => _TBtnState();
}

class _TBtnState extends State<_TBtn> with SingleTickerProviderStateMixin {
  late final AnimationController _spinCtrl;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    if (widget.isLoading) _spinCtrl.repeat();
  }

  @override
  void didUpdateWidget(_TBtn old) {
    super.didUpdateWidget(old);
    if (widget.isLoading && !_spinCtrl.isAnimating) {
      _spinCtrl.repeat();
    } else if (!widget.isLoading && _spinCtrl.isAnimating) {
      _spinCtrl.stop();
      _spinCtrl.reset();
    }
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        if (!widget.isLoading) widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 0.8),
            borderRadius: BorderRadius.circular(8),
            color: _pressed
                ? color.withOpacity(0.18)
                : color.withOpacity(0.07),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            widget.isLoading
                ? RotationTransition(
                    turns: _spinCtrl,
                    child: Icon(widget.icon, color: color, size: 14),
                  )
                : Icon(widget.icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(widget.label,
                style: GoogleFonts.poppins(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String msg;
  final Color color;
  const _Banner({required this.icon, required this.msg, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Text(msg, style: GoogleFonts.poppins(color: color, fontSize: 12)),
        ]),
      );
}
