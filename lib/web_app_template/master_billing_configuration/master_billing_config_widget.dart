// master_billing_config_widget.dart
//
// Changes from v1:
//  • VoltageCategory enum replaced by dynamic ActiveCategory fetched from
//    /tariff-category/list/active.  The tariffCategory doc-id is now used as
//    the masterBillingConfig category key — so N categories work automatically.
//  • Orphaned configs (category deleted while billing data still exists) are
//    detected and shown with a dismissible warning banner.
//  • Deploy now also saves electricity tariff to settings/electricityTariff
//    so /tnbE3Simulator can read peakRate & offPeakRate.
//  • Cycle Effective Date now uses a date picker (format YYYY-MM-DD).

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/components/page_header/breadcrumb_item.dart';
import 'package:smartmachine365/components/page_header/page_header_widget.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_theme.dart';
import 'package:smartmachine365/web_app_template/master_billing_configuration/billing_field_row_widget.dart';
import 'package:smartmachine365/web_app_template/master_billing_configuration/billing_section_card_widget.dart';
import 'package:smartmachine365/web_app_template/master_billing_configuration/deploy_button_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';

const String _kApiBaseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

class ActiveCategory {
  final String id;
  final String tariffCategory;

  const ActiveCategory({
    required this.id,
    required this.tariffCategory,
  });

  @override
  bool operator ==(Object other) => other is ActiveCategory && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class OrphanInfo {
  final String categoryId;
  final Map<String, String> savedConfig;
  const OrphanInfo({required this.categoryId, required this.savedConfig});
}

class MasterBillingConfigWidget extends StatefulWidget {
  const MasterBillingConfigWidget({super.key});

  @override
  State<MasterBillingConfigWidget> createState() => _MasterBillingConfigWidgetState();
}

class _MasterBillingConfigWidgetState extends State<MasterBillingConfigWidget> {
  List<ActiveCategory> _categories = [];
  ActiveCategory? _selectedCategory;

  final Map<String, Map<String, TextEditingController>> _allCtrl = {};

  bool _isDeploying = false;
  bool _isApplying = false;
  bool _isLoading = true;

  String? _appliedCategoryId;

  final List<OrphanInfo> _orphans = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    try {
      // Tariff categories are centralized per tenant — every user reads the
      // same shared list, so no more copying defaults from an admin account.
      await _loadCategories();
      await _loadFromApi();
      if (_orphans.isNotEmpty) {
        await _autoFixOrphans();
        _orphans.clear();
        await _loadFromApi();
      }
    } finally {
      // Whatever happens above (including uncaught cast Errors from an
      // unexpected API response), never leave the page stuck on the spinner.
      if (mounted && _isLoading) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    for (final m in _allCtrl.values) {
      for (final c in m.values) c.dispose();
    }
    super.dispose();
  }

  // ── Build blank controllers ───────────────────────────────────────────────

  Map<String, TextEditingController> _buildControllers() {
    final ctrls = <String, TextEditingController>{
      'mdCapacity': TextEditingController(),
      'mdNetwork': TextEditingController(),
      'retail': TextEditingController(),
      'baseEnergy': TextEditingController(),
      'afa': TextEditingController(),
      'minMonthly': TextEditingController(),
      'targetPF': TextEditingController(),
      'tier1Rate': TextEditingController(),
      'tier2Trigger': TextEditingController(),
      'tier2Rate': TextEditingController(),
      'kwtbb': TextEditingController(),
      'sst': TextEditingController(),
      'date': TextEditingController(),
      'peakRate': TextEditingController(text: '0.355'),
      'normalRate': TextEditingController(text: '0.217'),
      'offPeakRate': TextEditingController(text: '0.217'),
      'capacityRate': TextEditingController(text: '30.30'),
    };

    void recompute() {
      final a = double.tryParse(ctrls['mdCapacity']!.text.trim()) ?? 0;
      final b = double.tryParse(ctrls['mdNetwork']!.text.trim()) ?? 0;
      final sum = (a + b).toStringAsFixed(2);
      if (ctrls['capacityRate']!.text != sum) {
        ctrls['capacityRate']!.text = sum;
      }
    }

    ctrls['mdCapacity']!.addListener(recompute);
    ctrls['mdNetwork']!.addListener(recompute);

    return ctrls;
  }

  // ── Load active tariff categories ─────────────────────────────────────────

  Future<void> _loadCategories() async {
    // Billing config is shared across every user of this client, not
    // per-login — see AppConfig.sharedConfigOwnerId.
    const uid = AppConfig.sharedConfigOwnerId;
    if (uid.isEmpty) return;

    try {
      final response = await http
          .get(
            Uri.parse('$_kApiBaseUrl/tariff-categories/list/active?userId=$uid'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        // Defensive parsing — a hard `as String` cast on a missing field
        // throws an uncatchable-here TypeError that used to kill _init()
        // and leave the page stuck on the loading spinner forever.
        final list = ((body['data'] as List<dynamic>?) ?? [])
            .whereType<Map<String, dynamic>>()
            .map((item) => ActiveCategory(
                  id: item['id']?.toString() ?? '',
                  tariffCategory: (item['tariffCategory'] ?? item['voltageName'] ?? item['id'] ?? '').toString(),
                ))
            .where((c) => c.id.isNotEmpty)
            .toList();

        if (mounted) {
          setState(() {
            _categories = list;
            for (final cat in list) {
              _allCtrl.putIfAbsent(cat.id, _buildControllers);
            }
            if (_categories.isNotEmpty) {
              _selectedCategory = _categories.first;
            }
          });
        }
      }
    } on Exception catch (_) {}
  }

  // ── Auto-fix orphaned billing configs ──────────────────────────────────
  // Categories are centralized per tenant now, so an orphaned billing config
  // (its category was deleted from the shared list) is simply removed —
  // no more remapping/copying from an admin account.
  Future<void> _autoFixOrphans() async {
    // Billing config is shared across every user of this client, not
    // per-login — see AppConfig.sharedConfigOwnerId.
    const uid = AppConfig.sharedConfigOwnerId;
    if (uid.isEmpty || _orphans.isEmpty) return;

    try {
      for (final orphan in _orphans) {
        await http
            .delete(
              Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/${orphan.categoryId}'),
              headers: AppConfig.headers,
            )
            .timeout(const Duration(seconds: 10));
      }

      // Clear the applied pointer if it referenced a deleted category.
      if (_appliedCategoryId != null && !_categories.any((c) => c.id == _appliedCategoryId)) {
        await http
            .delete(
              Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/applied'),
              headers: AppConfig.headers,
            )
            .timeout(const Duration(seconds: 10));
      }
    } catch (_) {}
  }

  // ── Load saved billing configs ────────────────────────────────────────────

  Future<void> _loadFromApi() async {
    // Billing config is shared across every user of this client, not
    // per-login — see AppConfig.sharedConfigOwnerId.
    const uid = AppConfig.sharedConfigOwnerId;
    if (uid.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final results = await Future.wait([
        http.get(Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid'), headers: AppConfig.headers).timeout(const Duration(seconds: 15)),
        http.get(Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/applied'), headers: AppConfig.headers).timeout(const Duration(seconds: 15)),
        http.get(Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/electricityTariff'), headers: AppConfig.headers).timeout(const Duration(seconds: 15)),
      ]);

      final configResponse = results[0];
      final appliedResponse = results[1];
      final tariffResponse = results[2];

      if (configResponse.statusCode == 200) {
        final data = jsonDecode(configResponse.body) as Map<String, dynamic>;
        final saved = (data['categories'] as Map<String, dynamic>?) ?? {};
        final activeCatIds = _categories.map((c) => c.id).toSet();

        for (final entry in saved.entries) {
          final catId = entry.key;
          final fields = entry.value as Map<String, dynamic>;

          _allCtrl.putIfAbsent(catId, _buildControllers);

          final c = _allCtrl[catId]!;
          _setText(c['mdCapacity'], fields['mdCapacityCharge']);
          _setText(c['mdNetwork'], fields['mdNetworkCharge']);
          _setText(c['retail'], fields['retailCharge']);
          _setText(c['baseEnergy'], fields['baseEnergyRate']);
          _setText(c['afa'], fields['currentAFA']);
          _setText(c['minMonthly'], fields['minMonthlyCharge']);
          _setText(c['targetPF'], fields['targetThreshold']);
          _setText(c['tier1Rate'], fields['tier1Rate']);
          _setText(c['tier2Trigger'], fields['tier2Trigger']);
          _setText(c['tier2Rate'], fields['tier2Rate']);
          _setText(c['kwtbb'], fields['kwtbb']);
          _setText(c['sst'], fields['sst']);
          _setText(c['date'], fields['cycleEffectiveDate']);
          _setText(c['peakRate'], fields['peakRate']);
          _setText(c['normalRate'], fields['normalRate']);
          _setText(c['offPeakRate'], fields['offPeakRate']);
          _setText(c['capacityRate'], fields['capacityRate']);

          if (!activeCatIds.contains(catId)) {
            _orphans.add(OrphanInfo(
              categoryId: catId,
              savedConfig: fields.map((k, v) => MapEntry(k, v.toString())),
            ));
          }
        }
      }

      if (appliedResponse.statusCode == 200) {
        final appliedData = jsonDecode(appliedResponse.body) as Map<String, dynamic>;
        _appliedCategoryId = appliedData['appliedCategory'] as String?;
      }

      if (tariffResponse.statusCode == 200) {
        // Deploy saves peakRate/normalRate/offPeakRate/capacityRate to a
        // single shared settings/electricityTariff doc (not per-category —
        // see /tnbE3Simulator note at the top of this file), so apply it to
        // every category's controllers rather than looking it up per catId.
        final tariff = jsonDecode(tariffResponse.body) as Map<String, dynamic>;
        for (final c in _allCtrl.values) {
          _setText(c['peakRate'], tariff['peakRate']);
          _setText(c['normalRate'], tariff['normalRate']);
          _setText(c['offPeakRate'], tariff['offPeakRate']);
          _setText(c['capacityRate'], tariff['capacityRate']);
        }
      }
    } on Exception catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          if (_appliedCategoryId != null) {
            final appliedCat = _categories.where((c) => c.id == _appliedCategoryId).firstOrNull;
            if (appliedCat != null) _selectedCategory = appliedCat;
          }
          _isLoading = false;
        });
      }
    }
  }

  void _setText(TextEditingController? ctrl, dynamic value) {
    if (ctrl != null && value != null) ctrl.text = value.toString();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Map<String, TextEditingController> get _ctrl => _allCtrl[_selectedCategory!.id]!;

  bool get _isCurrentCategoryApplied => _appliedCategoryId == _selectedCategory?.id;

  bool get _isBlockedByOtherApplied => _appliedCategoryId != null && _appliedCategoryId != _selectedCategory?.id;

  void _switchCategory(ActiveCategory cat) => setState(() => _selectedCategory = cat);

  // ── Date picker ───────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final now = DateTime.now();

    DateTime initial = now;
    try {
      if (_ctrl['date']!.text.isNotEmpty) {
        initial = DateTime.parse(_ctrl['date']!.text);
      }
    } catch (_) {}

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF2DC76D),
              onPrimary: Colors.white,
              surface: Color.fromRGBO(0, 4, 51, 1),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && mounted) {
      setState(() {
        _ctrl['date']!.text = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      });
    }
  }

  // ── Build payload ─────────────────────────────────────────────────────────

  Map<String, String> _buildPayload(ActiveCategory cat) {
    final c = _allCtrl[cat.id]!;
    return {
      'mdCapacityCharge': c['mdCapacity']!.text.trim(),
      'mdCapacityUnit': 'RM/kW/month',
      'mdNetworkCharge': c['mdNetwork']!.text.trim(),
      'mdNetworkUnit': 'RM/kW/month',
      'retailCharge': c['retail']!.text.trim(),
      'baseEnergyRate': c['baseEnergy']!.text.trim(),
      'currentAFA': c['afa']!.text.trim(),
      'minMonthlyCharge': c['minMonthly']!.text.trim(),
      'targetThreshold': c['targetPF']!.text.trim(),
      'tier1Rate': c['tier1Rate']!.text.trim(),
      'tier2Trigger': c['tier2Trigger']!.text.trim(),
      'tier2Rate': c['tier2Rate']!.text.trim(),
      'kwtbb': c['kwtbb']!.text.trim(),
      'sst': c['sst']!.text.trim(),
      'cycleEffectiveDate': c['date']!.text.trim(),
      'peakRate': c['peakRate']!.text.trim(),
      'normalRate': c['normalRate']!.text.trim(),
      'offPeakRate': c['offPeakRate']!.text.trim(),
      'capacityRate': c['capacityRate']!.text.trim(),
    };
  }

  // ── Deploy ────────────────────────────────────────────────────────────────

  Future<void> _deployCategory() async {
    // Billing config is shared across every user of this client, not
    // per-login — see AppConfig.sharedConfigOwnerId.
    const uid = AppConfig.sharedConfigOwnerId;
    if (uid.isEmpty || _selectedCategory == null) {
      _showSnack('User not logged in', isError: true);
      return;
    }

    setState(() => _isDeploying = true);
    try {
      final catId = _selectedCategory!.id;
      final uri = Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/$catId');
      final response = await http
          .post(
            uri,
            headers: AppConfig.headers,
            body: jsonEncode(_buildPayload(_selectedCategory!)),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 201) {
        _showSnack('${_selectedCategory!.tariffCategory} config saved ✓');

        final tariffUri = Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/electricityTariff');
        await http
            .post(
              tariffUri,
              headers: AppConfig.headers,
              body: jsonEncode({
                'peakRate': double.tryParse(_ctrl['peakRate']!.text.trim()) ?? 0,
                'normalRate': double.tryParse(_ctrl['normalRate']!.text.trim()) ?? 0,
                'offPeakRate': double.tryParse(_ctrl['offPeakRate']!.text.trim()) ?? 0,
                'capacityRate': double.tryParse(_ctrl['capacityRate']!.text.trim()) ?? 0,
              }),
            )
            .timeout(const Duration(seconds: 15));
      } else {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        _showSnack(
          decoded['error']?.toString() ?? 'Unexpected error (${response.statusCode})',
          isError: true,
        );
      }
    } on Exception catch (e) {
      _showSnack('Network error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isDeploying = false);
    }
  }

  // ── Apply ─────────────────────────────────────────────────────────────────

  Future<void> _applyCategory() async {
    // Billing config is shared across every user of this client, not
    // per-login — see AppConfig.sharedConfigOwnerId.
    const uid = AppConfig.sharedConfigOwnerId;
    if (uid.isEmpty || _selectedCategory == null) {
      _showSnack('User not logged in', isError: true);
      return;
    }

    if (_appliedCategoryId != null && _appliedCategoryId != _selectedCategory!.id) {
      final blockedName = _categories
          .firstWhere(
            (c) => c.id == _appliedCategoryId,
            orElse: () => ActiveCategory(
              id: _appliedCategoryId!,
              tariffCategory: _appliedCategoryId!,
            ),
          )
          .tariffCategory;
      _showSnack('$blockedName is already applied. Clear it first.', isError: true);
      return;
    }

    if (_isCurrentCategoryApplied) {
      _showSnack('${_selectedCategory!.tariffCategory} is already active.');
      return;
    }

    setState(() => _isApplying = true);
    try {
      final catId = _selectedCategory!.id;
      final uri = Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/$catId/apply');
      final response = await http.post(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        setState(() => _appliedCategoryId = catId);
        _showSnack('${_selectedCategory!.tariffCategory} is now active ✓');
      } else {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        _showSnack(
          decoded['error']?.toString() ?? 'Unexpected error (${response.statusCode})',
          isError: true,
        );
      }
    } on Exception catch (e) {
      _showSnack('Network error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
  }

  // ── Unapply ───────────────────────────────────────────────────────────────

  Future<void> _unapplyCategory() async {
    // Billing config is shared across every user of this client, not
    // per-login — see AppConfig.sharedConfigOwnerId.
    const uid = AppConfig.sharedConfigOwnerId;
    if (uid.isEmpty) return;

    setState(() => _isApplying = true);
    try {
      final uri = Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/applied');
      final response = await http.delete(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        setState(() => _appliedCategoryId = null);
        _showSnack('Active config cleared');
      } else {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        _showSnack(
          decoded['error']?.toString() ?? 'Unexpected error (${response.statusCode})',
          isError: true,
        );
      }
    } on Exception catch (e) {
      _showSnack('Network error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
  }

  // ── Delete orphan ─────────────────────────────────────────────────────────

  Future<void> _deleteOrphan(OrphanInfo orphan) async {
    // Billing config is shared across every user of this client, not
    // per-login — see AppConfig.sharedConfigOwnerId.
    const uid = AppConfig.sharedConfigOwnerId;
    try {
      await http
          .delete(
            Uri.parse('$_kApiBaseUrl/masterBillingConfig/$uid/${orphan.categoryId}'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));

      if (mounted) {
        setState(() => _orphans.removeWhere((o) => o.categoryId == orphan.categoryId));
        _showSnack('Orphaned config removed');
      }
    } on Exception catch (e) {
      _showSnack('Failed to remove orphan: $e', isError: true);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color(0xFFE53935) : const Color(0xFF2DC76D),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: theme.primaryBackground,
          image: DecorationImage(
            fit: BoxFit.cover,
            image: Image.asset('assets/images/backgroundanimated.gif').image,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageHeader(
              breadcrumbs: const [
                BreadcrumbItem(label: 'Settings', icon: Icons.settings),
                BreadcrumbItem(label: 'Energy & Billing'),
                BreadcrumbItem(label: 'Master Billing Configuration'),
              ],
              title: 'Master Billing Configuration',
              subtitle: 'Unbundled Tariff Settings • RP4 Compliance (2025–2027)',
              trailing: _buildCategoryDropdown(),
            ),
            if (_isLoading)
              Expanded(
                child: Center(child: CircularProgressIndicator(color: theme.primary)),
              )
            else if (_categories.isEmpty)
              Expanded(child: _buildEmptyState())
            else
              Expanded(
                child: LayoutBuilder(
                  key: ValueKey(_selectedCategory?.id),
                  builder: (context, constraints) {
                    final banners = [
                      ..._orphans.map(_buildOrphanBanner),
                      if (_orphans.isNotEmpty) const SizedBox(height: 8),
                      if (_appliedCategoryId != null) _buildAppliedBanner(),
                      const SizedBox(height: 8),
                    ];

                    // Estimate minimum natural content height:
                    // main row (~240px) + gap(16) + bottom row (~160px) + gap(20) + buttons(52) + padding(36)
                    const double kNaturalContentH = 524;
                    final bool canFill = constraints.maxHeight >= kNaturalContentH;

                    if (canFill) {
                      // Enough height — stretch cards to fill all space, no blank bottom
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...banners,
                            Expanded(flex: 3, child: _buildMainRowFill(context)),
                            const SizedBox(height: 16),
                            Expanded(flex: 2, child: _buildBottomRowFill(context)),
                            const SizedBox(height: 20),
                            _buildActionButtons(),
                          ],
                        ),
                      );
                    } else {
                      // Not enough height — scroll, cards at natural height, no overflow
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...banners,
                            _buildMainRowNatural(context),
                            const SizedBox(height: 16),
                            _buildBottomRowNatural(context),
                            const SizedBox(height: 20),
                            _buildActionButtons(),
                          ],
                        ),
                      );
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.category_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text('No active tariff categories found.', style: GoogleFonts.poppins(fontSize: 14, color: Colors.grey)),
          const SizedBox(height: 4),
          Text('Create categories in Tariff Category Setup first.', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  // ── Orphan banner ─────────────────────────────────────────────────────────

  Widget _buildOrphanBanner(OrphanInfo orphan) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFF6F00).withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF6F00)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF6F00), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Orphaned billing config — category "${orphan.categoryId}" was deleted. '
              'Its saved data still exists. Delete it to clean up.',
              style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFFF6F00)),
            ),
          ),
          TextButton(
            onPressed: () => _deleteOrphan(orphan),
            child: Text('Delete', style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFE53935))),
          ),
        ],
      ),
    );
  }

  // ── Applied banner ────────────────────────────────────────────────────────

  Widget _buildAppliedBanner() {
    final appliedCat = _categories.firstWhere(
      (c) => c.id == _appliedCategoryId,
      orElse: () => ActiveCategory(
        id: _appliedCategoryId!,
        tariffCategory: _appliedCategoryId!,
      ),
    );
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kGreen.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kGreen.withOpacity(0.5), width: 1),
        boxShadow: isLight
            ? null
            : [
                BoxShadow(color: kGreen.withOpacity(0.08), blurRadius: 12),
              ],
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: kGreen, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '[ ${appliedCat.tariffCategory} ]  —  Currently active billing config',
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: kGreen,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
          TextButton(
            onPressed: _isApplying ? null : _unapplyCategory,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('Clear', style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFE53935))),
          ),
        ],
      ),
    );
  }

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _buildActionButtons() {
    final theme = FlutterFlowTheme.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Column(
      children: [
        Divider(color: theme.cardStroke, height: 1),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _isDeploying ? Center(child: CircularProgressIndicator(color: kGreen)) : DeployButton(onPressed: _deployCategory),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _isApplying ? Center(child: CircularProgressIndicator(color: theme.primary)) : _buildApplyButton(theme, isLight),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildApplyButton(FlutterFlowTheme theme, bool isLight) {
    final isApplied = _isCurrentCategoryApplied;
    final isBlocked = _isBlockedByOtherApplied;

    final Color accent;
    final String label;
    final IconData icon;
    final VoidCallback? onTap;

    if (isApplied) {
      accent = kGreen;
      label = 'Active';
      icon = Icons.check_circle_outline;
      onTap = null;
    } else if (isBlocked) {
      accent = isLight ? const Color(0xFF9CA3AF) : const Color(0xFF4B5563);
      label = 'Apply';
      icon = Icons.block;
      onTap = null;
    } else {
      accent = theme.primary;
      label = 'Apply Config';
      icon = Icons.play_circle_outline;
      onTap = _applyCategory;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: accent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withOpacity(0.6), width: 1.5),
          boxShadow: (!isLight && onTap != null) ? [BoxShadow(color: accent.withOpacity(0.15), blurRadius: 12, offset: const Offset(0, 4))] : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: accent, size: 18),
            const SizedBox(width: 8),
            Text(label, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: accent)),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryDropdown() {
    if (_categories.isEmpty) return const SizedBox.shrink();
    return Builder(builder: (ctx) {
      final theme = FlutterFlowTheme.of(ctx);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: theme.primaryBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.cardStroke),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<ActiveCategory>(
            value: _selectedCategory,
            dropdownColor: theme.secondaryBackground,
            style: GoogleFonts.poppins(color: theme.primaryText, fontSize: 13),
            iconEnabledColor: theme.secondaryText,
            items: _categories.map((cat) {
              final isApplied = cat.id == _appliedCategoryId;
              return DropdownMenuItem<ActiveCategory>(
                value: cat,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(cat.tariffCategory),
                    if (isApplied) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.circle, color: Color(0xFF2DC76D), size: 8),
                    ],
                  ],
                ),
              );
            }).toList(),
            onChanged: (cat) {
              if (cat != null) _switchCategory(cat);
            },
          ),
        ),
      );
    });
  }

  // ── Form cards ────────────────────────────────────────────────────────────

  List<Widget> _mainCards(FlutterFlowTheme theme) => [
        _electricityTariffCard(theme),
        _gridInfraCard(theme),
        _variableEnergyCard(theme),
        _pfSurchargeCard(theme),
      ];

  // Fill mode: parent (Expanded) controls height, cards stretch
  Widget _buildMainRowFill(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final isWide = MediaQuery.of(context).size.width > 700;
    final cards = _mainCards(theme);
    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: cards[0]),
          const SizedBox(width: 14),
          Expanded(child: cards[1]),
          const SizedBox(width: 14),
          Expanded(child: cards[2]),
          const SizedBox(width: 14),
          Expanded(child: cards[3]),
        ],
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      cards[0],
      const SizedBox(height: 14),
      cards[1],
      const SizedBox(height: 14),
      cards[2],
      const SizedBox(height: 14),
      cards[3],
    ]);
  }

  // Natural mode: scroll layout, IntrinsicHeight makes all cards same height
  Widget _buildMainRowNatural(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final isWide = MediaQuery.of(context).size.width > 700;
    final cards = _mainCards(theme);
    if (isWide) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 14),
            Expanded(child: cards[1]),
            const SizedBox(width: 14),
            Expanded(child: cards[2]),
            const SizedBox(width: 14),
            Expanded(child: cards[3]),
          ],
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      cards[0],
      const SizedBox(height: 14),
      cards[1],
      const SizedBox(height: 14),
      cards[2],
      const SizedBox(height: 14),
      cards[3],
    ]);
  }

  Widget _electricityTariffCard(FlutterFlowTheme theme) => BillingSectionCard(
        icon: '⚡',
        title: 'ELECTRICITY TARIFF',
        accentColor: theme.primary,
        children: [
          BillingFieldRow(label: 'Peak Rate', unit: 'RM/kWh', controller: _ctrl['peakRate']!),
          BillingFieldRow(label: 'Normal Rate', unit: 'RM/kWh', controller: _ctrl['normalRate']!),
          BillingFieldRow(label: 'Off-Peak Rate', unit: 'RM/kWh', controller: _ctrl['offPeakRate']!),
          BillingFieldRow(label: 'Capacity Rate', unit: 'RM/kW', controller: _ctrl['capacityRate']!),
        ],
      );

  Widget _gridInfraCard(FlutterFlowTheme theme) => BillingSectionCard(
        icon: '⚡',
        title: 'GRID INFRASTRUCTURE (MD CHARGE)',
        accentColor: theme.secondary,
        children: [
          BillingFieldRow(label: 'MD Capacity Charge', unit: 'RM/kW/month', controller: _ctrl['mdCapacity']!),
          BillingFieldRow(label: 'MD Network Charge', unit: 'RM/kW/month', controller: _ctrl['mdNetwork']!),
          BillingFieldRow(label: 'Retail Charge', unit: 'RM/month', controller: _ctrl['retail']!),
          const SizedBox(height: 4),
          Builder(
              builder: (ctx) => Text(
                    '*For MV/HV, MD is based on Peak kW. For LV, MD is bundled into kWh rates.',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: FlutterFlowTheme.of(ctx).secondaryText,
                      fontStyle: FontStyle.italic,
                    ),
                  )),
        ],
      );

  Widget _variableEnergyCard(FlutterFlowTheme theme) => BillingSectionCard(
        icon: '⚡',
        title: 'VARIABLE ENERGY',
        accentColor: theme.warning,
        children: [
          BillingFieldRow(label: 'Base Energy Rate', unit: 'RM/kWh', controller: _ctrl['baseEnergy']!),
          BillingFieldRow(label: 'Current AFA', unit: 'RM/kWh', controller: _ctrl['afa']!),
          BillingFieldRow(label: 'Min. Monthly Charge', unit: 'RM', controller: _ctrl['minMonthly']!),
        ],
      );

  Widget _pfSurchargeCard(FlutterFlowTheme theme) => BillingSectionCard(
        icon: '⚡',
        title: 'PF SURCHARGE RULES',
        accentColor: theme.warning,
        children: [
          BillingFieldRow(label: 'Tier 1 Threshold', unit: 'PF', controller: _ctrl['targetPF']!),
          BillingFieldRow(label: 'Tier 1 Rate', unit: '% per 0.01 drop', controller: _ctrl['tier1Rate']!),
          BillingFieldRow(label: 'Tier 2 Threshold', unit: 'PF', controller: _ctrl['tier2Trigger']!),
          BillingFieldRow(label: 'Tier 2 Rate', unit: '% per 0.01 drop', controller: _ctrl['tier2Rate']!),
        ],
      );

  // Fill mode: parent (Expanded) controls height
  Widget _buildBottomRowFill(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final isWide = MediaQuery.of(context).size.width > 700;
    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _leviesCard(theme)),
          const SizedBox(width: 14),
          Expanded(child: _metadataCard(theme)),
        ],
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _leviesCard(theme),
      const SizedBox(height: 14),
      _metadataCard(theme),
    ]);
  }

  // Natural mode: IntrinsicHeight equalises card heights
  Widget _buildBottomRowNatural(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final isWide = MediaQuery.of(context).size.width > 700;
    if (isWide) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _leviesCard(theme)),
            const SizedBox(width: 14),
            Expanded(child: _metadataCard(theme)),
          ],
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _leviesCard(theme),
      const SizedBox(height: 14),
      _metadataCard(theme),
    ]);
  }

  Widget _leviesCard(FlutterFlowTheme theme) => BillingSectionCard(
        icon: '💰',
        title: 'STATUTORY LEVIES',
        accentColor: theme.secondary,
        children: [
          Row(
            children: [
              Expanded(
                child: BillingFieldRow(
                  label: 'KWTBB (RE Fund)',
                  unit: '%',
                  controller: _ctrl['kwtbb']!,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BillingFieldRow(
                  label: 'Service Tax (SST)',
                  unit: '%',
                  controller: _ctrl['sst']!,
                ),
              ),
            ],
          ),
        ],
      );

  Widget _metadataCard(FlutterFlowTheme theme) => BillingSectionCard(
        icon: '📅',
        title: 'CONFIGURATION METADATA',
        accentColor: theme.primary,
        children: [
          Builder(builder: (ctx) {
            final t = FlutterFlowTheme.of(ctx);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cycle Effective Date',
                  style: GoogleFonts.poppins(
                    color: t.secondaryText,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _pickDate,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).brightness == Brightness.light ? const Color(0xFFF8FAFC) : const Color(0xFF0D1117),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(ctx).brightness == Brightness.light ? const Color(0xFFCBD5E1) : const Color(0xFF2C354A),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.calendar_today, color: t.primary, size: 16),
                        const SizedBox(width: 10),
                        Text(
                          _ctrl['date']!.text.isNotEmpty ? _ctrl['date']!.text : 'Select date...',
                          style: GoogleFonts.poppins(
                            color: _ctrl['date']!.text.isNotEmpty ? t.primaryText : t.secondaryText,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: 8),
          Builder(
              builder: (ctx) => Text(
                    'Note: Unbundled Network Charges are revised every Regulatory Period (3 years).',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: FlutterFlowTheme.of(ctx).secondaryText,
                      fontStyle: FontStyle.italic,
                    ),
                  )),
        ],
      );
}
