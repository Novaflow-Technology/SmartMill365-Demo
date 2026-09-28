import 'dart:async';
import 'package:flutter/material.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/web_app_template/pom_command_center/pom_config.dart';
import 'package:smartmachine365/web_app_template/pom_command_center/pom_dashboard_view.dart';

/// Group POM (Palm Oil Mill) Command Center — Sarawak Operations.
///
/// Shows whatever was last published from the Kanban Dashboard Setting page,
/// with every figure read live from SmartMill's own Influx/MySQL through
/// [PomLiveData] — nothing here is a fixed number baked into the app.
class PomGroupCommandCenterWidget extends StatefulWidget {
  const PomGroupCommandCenterWidget({super.key});

  @override
  State<PomGroupCommandCenterWidget> createState() => _PomGroupCommandCenterWidgetState();
}

class _PomGroupCommandCenterWidgetState extends State<PomGroupCommandCenterWidget> {
  bool _ready = false;
  String _period = 'today';
  final Map<String, String> _panelPeriod = {};
  Map<String, double> _live = {};
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    PomConfigStore.ensureLoaded().then((_) async {
      if (!mounted) return;
      final c = PomCalc(PomConfigStore.live);
      final en = c.enabledPeriods();
      final def = c.top['defPeriod'].toString();
      await PomLiveData.ensureDevicesLoaded();
      final live = await PomLiveData.fetchValues(c.mappedPoints());
      if (!mounted) return;
      setState(() {
        _period = en.contains(def) ? def : (en.isNotEmpty ? en.first : 'today');
        _live = live;
        _ready = true;
      });
      // Refreshes on its own so a card left open keeps showing current
      // readings, the way a command centre TV wall is expected to.
      _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshLive());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLive() async {
    final c = PomCalc(PomConfigStore.live);
    final live = await PomLiveData.fetchValues(c.mappedPoints());
    if (!mounted) return;
    setState(() => _live = live);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF040B1A),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : PomScaledCanvas(
              child: PomDashboardView(
                cfg: PomConfigStore.live,
                period: _period,
                panelPeriod: _panelPeriod,
                live: _live,
                onPeriod: (p) => setState(() => _period = p),
                onPanelPeriod: (panel, p) => setState(() => _panelPeriod[panel] = p),
                onMillTap: (millId) => context.pushNamed('MillCommandCenter', queryParameters: {'mill': millId}),
              ),
            ),
    );
  }
}
