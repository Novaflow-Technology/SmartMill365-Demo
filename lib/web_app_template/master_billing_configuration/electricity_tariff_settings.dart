import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_widgets.dart';

const String _kApiBaseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

class ElectricityTariffSettings extends StatefulWidget {
  final String uid;
  final Function(Map<String, dynamic>)? onSaved;

  const ElectricityTariffSettings({
    super.key,
    required this.uid,
    this.onSaved,
  });

  @override
  State<ElectricityTariffSettings> createState() => _ElectricityTariffSettingsState();
}

class _ElectricityTariffSettingsState extends State<ElectricityTariffSettings> {
  final TextEditingController _peakRateController = TextEditingController(text: '0.355');
  final TextEditingController _normalRateController = TextEditingController(text: '0.217');
  final TextEditingController _offPeakRateController = TextEditingController(text: '0.217');
  final TextEditingController _capacityRateController = TextEditingController(text: '30.30');

  bool _isLoading = false;
  bool _isSaving = false;

  String _originalPeakRate = '0.355';
  String _originalNormalRate = '0.217';
  String _originalOffPeakRate = '0.217';
  String _originalCapacityRate = '30.30';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSettings());
  }

  @override
  void dispose() {
    _peakRateController.dispose();
    _normalRateController.dispose();
    _offPeakRateController.dispose();
    _capacityRateController.dispose();
    super.dispose();
  }

  // ── Load ──────────────────────────────────────────────────────────────────
  Future<void> _loadSettings() async {
    if (widget.uid.isEmpty) return;

    try {
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/masterBillingConfig/${widget.uid}/electricityTariff'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _peakRateController.text = data['peakRate']?.toString() ?? '0.355';
            _normalRateController.text = data['normalRate']?.toString() ?? '0.217';
            _offPeakRateController.text = data['offPeakRate']?.toString() ?? '0.217';
            _capacityRateController.text = data['capacityRate']?.toString() ?? '30.30';

            _originalPeakRate = _peakRateController.text;
            _originalNormalRate = _normalRateController.text;
            _originalOffPeakRate = _offPeakRateController.text;
            _originalCapacityRate = _capacityRateController.text;
          });
        }
      }
      // 404 = belum ada data, biarkan default values
    } on Exception catch (_) {
      // Silently fall back to defaults on network error
    }
  }

  // ── Save ──────────────────────────────────────────────────────────────────
  Future<void> _saveSettings() async {
    final peakRate = double.tryParse(_peakRateController.text);
    final normalRate = double.tryParse(_normalRateController.text);
    final offPeakRate = double.tryParse(_offPeakRateController.text);
    final capacityRate = double.tryParse(_capacityRateController.text);

    if (peakRate == null || peakRate < 0) {
      _showSnack('Peak rate must be a non-negative number', isError: true);
      return;
    }
    if (normalRate == null || normalRate < 0) {
      _showSnack('Normal rate must be a non-negative number', isError: true);
      return;
    }
    if (offPeakRate == null || offPeakRate < 0) {
      _showSnack('Off-peak rate must be a non-negative number', isError: true);
      return;
    }
    if (capacityRate == null || capacityRate < 0) {
      _showSnack('Capacity rate must be a non-negative number', isError: true);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final body = {
        'peakRate': peakRate,
        'normalRate': normalRate,
        'offPeakRate': offPeakRate,
        'capacityRate': capacityRate,
      };

      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/masterBillingConfig/${widget.uid}/electricityTariff'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        setState(() {
          _originalPeakRate = _peakRateController.text;
          _originalNormalRate = _normalRateController.text;
          _originalOffPeakRate = _offPeakRateController.text;
          _originalCapacityRate = _capacityRateController.text;
        });
        _showSnack('Electricity tariff settings saved successfully ✓');
        widget.onSaved?.call(body);
      } else {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final msg = decoded['error']?.toString() ?? 'Unexpected error (${response.statusCode})';
        _showSnack(msg, isError: true);
      }
    } on Exception catch (e) {
      _showSnack('Network error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _cancelChanges() {
    setState(() {
      _peakRateController.text = _originalPeakRate;
      _normalRateController.text = _originalNormalRate;
      _offPeakRateController.text = _originalOffPeakRate;
      _capacityRateController.text = _originalCapacityRate;
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFE53935) : const Color(0xFF2DC76D),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color.fromRGBO(0, 4, 51, 1),
        border: Border.all(
          color: FlutterFlowTheme.of(context).primary,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Electricity Tariff Settings',
                  style: FlutterFlowTheme.of(context).headlineSmall.override(
                        fontFamily: 'Poppins',
                        color: FlutterFlowTheme.of(context).info,
                        fontSize: 20,
                        letterSpacing: 0.0,
                        fontWeight: FontWeight.w600,
                        font: GoogleFonts.poppins(),
                      ),
                ),
                const SizedBox(height: 24),
                _buildField('Peak Period Rate (RM/kWh)', _peakRateController),
                const SizedBox(height: 20),
                _buildField('Normal Period Rate (RM/kWh)', _normalRateController),
                const SizedBox(height: 20),
                _buildField('Off-Peak Period Rate (RM/kWh)', _offPeakRateController),
                const SizedBox(height: 20),
                _buildField('Capacity Rate (RM/kW)', _capacityRateController),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FFButtonWidget(
                      onPressed: _isSaving ? null : _cancelChanges,
                      text: 'Cancel',
                      options: FFButtonOptions(
                        height: 44,
                        padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 0),
                        iconPadding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 0),
                        color: Colors.transparent,
                        textStyle: FlutterFlowTheme.of(context).titleSmall.override(
                              fontFamily: 'Poppins',
                              color: FlutterFlowTheme.of(context).primary,
                              letterSpacing: 0.0,
                              font: GoogleFonts.poppins(),
                            ),
                        elevation: 0,
                        borderSide: BorderSide(
                          color: FlutterFlowTheme.of(context).primary,
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FFButtonWidget(
                      onPressed: _isSaving ? null : _saveSettings,
                      text: _isSaving ? 'Saving...' : 'Save Settings',
                      options: FFButtonOptions(
                        height: 44,
                        padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 0),
                        iconPadding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 0),
                        color: FlutterFlowTheme.of(context).primary,
                        textStyle: FlutterFlowTheme.of(context).titleSmall.override(
                              fontFamily: 'Poppins',
                              color: Colors.white,
                              letterSpacing: 0.0,
                              font: GoogleFonts.poppins(),
                            ),
                        elevation: 0,
                        borderSide: const BorderSide(
                          color: Colors.transparent,
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildField(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: FlutterFlowTheme.of(context).bodyMedium.override(
                fontFamily: 'Poppins',
                color: FlutterFlowTheme.of(context).secondaryText,
                letterSpacing: 0.0,
                font: GoogleFonts.poppins(),
              ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          style: FlutterFlowTheme.of(context).bodyLarge.override(
                fontFamily: 'Poppins',
                color: FlutterFlowTheme.of(context).primaryText,
                letterSpacing: 0.0,
                font: GoogleFonts.poppins(),
              ),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color.fromRGBO(255, 255, 255, 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: FlutterFlowTheme.of(context).alternate, width: 1),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: FlutterFlowTheme.of(context).alternate, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: FlutterFlowTheme.of(context).primary, width: 1),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ],
    );
  }
}
