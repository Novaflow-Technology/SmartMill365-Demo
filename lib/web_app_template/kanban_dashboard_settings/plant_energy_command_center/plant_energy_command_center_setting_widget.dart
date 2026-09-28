import 'dart:convert';
import 'dart:math' as math;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/components/page_header/breadcrumb_item.dart';
import 'package:smartmachine365/components/page_header/page_header_widget.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/tnb_meter/tnb_meter_service.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/models/pecc_live_data.dart';

part '_pecc_models.dart';
part '_pecc_sections.dart';
part '_pecc_lot237_sections.dart';
part '_pecc_lot48_sections.dart';
part '_pecc_lot237blockb_sections.dart';
part '_pecc_lot237blockb_filters.dart';
part '_pecc_build.dart';
part '_pecc_sub_widgets.dart';

// ── Widget ─────────────────────────────────────────────────────────────────────

class PlantEnergyCommandCenterSettingWidget extends StatefulWidget {
  /// When set (e.g. "Lot 237"), the page opens pre-scoped to that factory:
  /// the PLANT dropdown starts on it and its own config is loaded. Empty/null
  /// → the group ("All plants") config, as before.
  final String? initialPlantName;

  /// When true, renders without the standalone page chrome (PageHeader /
  /// plant selector) so it can sit inside Factory Overview's Setting tab.
  final bool embedded;

  /// Called after a successful save (embedded: also used to refresh live data).
  final VoidCallback? onSaved;

  /// Embedded only — switch back to the Overview tab after save/apply.
  final VoidCallback? onApplyOverview;

  const PlantEnergyCommandCenterSettingWidget({
    super.key,
    this.initialPlantName,
    this.embedded = false,
    this.onSaved,
    this.onApplyOverview,
  });

  @override
  State<PlantEnergyCommandCenterSettingWidget> createState() => _PlantEnergyCommandCenterSettingWidgetState();
}

class _PlantEnergyCommandCenterSettingWidgetState extends State<PlantEnergyCommandCenterSettingWidget> {
  // ── Devices / loading ─────────────────────────────────────────────────────
  List<String> _devices = [];
  final Map<String, String> _deviceDisplayNames = {}; // deviceId -> friendly name from Master Facilities
  final Map<String, String> _deviceProductionAreas = {}; // deviceId -> production area from Master Facilities
  bool _isLoadingDevices = false;
  bool _isLoadingConfig = false;

  // Bumped on every _loadConfig() call so a slower, older request (e.g. from
  // a plant switched away from a moment ago) can never overwrite a newer
  // one's result after both resolve — without this, quickly switching
  // between plants could apply a stale response and the page would flash
  // back to whatever the previous plant's config looked like.
  int _configLoadVersion = 0;

  // ── Save state ────────────────────────────────────────────────────────────
  bool _isSaving = false;
  String _savingStatus = '';
  String? _saveMessage;
  bool _saveSuccess = false;

  // ── Filter bar ────────────────────────────────────────────────────────────
  static const List<String> _templateOptions = ['Plant Energy Command Center'];
  String _selectedTemplate = 'Plant Energy Command Center';

  List<Map<String, dynamic>> _plants = [];
  String _selectedPlantId = '';
  bool _isLoadingPlants = false;

  static const List<String> _mappingFilterOptions = ['All', 'Mapped', 'Unmapped'];
  String _mappingFilter = 'All';

  /// Empty → all production areas. Otherwise the widget device pickers only
  /// offer meters whose Master Facilities production area matches, so a section
  /// can only be wired to devices that actually sit in the selected area.
  String _selectedProductionArea = '';

  /// Production areas from the General Factory Setting master list
  /// (`/productionAreas`), scoped to the selected plant via factory_id — the
  /// same source Master Facilities fills the zone field from. Names are used as
  /// values because facilities store the area by name, not id.
  List<Map<String, String>> _productionAreaMaster = [];
  bool _isLoadingProductionAreas = false;

  List<String> get _productionAreaOptions {
    final fromMaster = _productionAreaMaster
        .map((a) => a['name'] ?? '')
        .where((n) => n.isNotEmpty)
        .toSet();
    // Union with areas actually present on devices, so a facility pointing at
    // an area that predates the master list stays selectable.
    fromMaster.addAll(_deviceProductionAreas.values.where((a) => a.isNotEmpty));
    final s = fromMaster.toList()..sort();
    return s;
  }

  Future<void> _fetchProductionAreas() async {
    if (mounted) setState(() => _isLoadingProductionAreas = true);
    try {
      var areas = await _getProductionAreas(factoryId: _selectedPlantId);
      // Areas are expected to link to their parent plant, but some rows link to
      // a block instead (e.g. "Block B Production Area" → plant "Lot 237 Block
      // B" rather than "Lot 237"), so scoping by the parent returns nothing.
      // Fall back to the full list rather than showing an empty dropdown. Fix
      // the links in General Factory Setting → Production Area to scope properly.
      if (areas.isEmpty && _selectedPlantId.isNotEmpty) {
        areas = await _getProductionAreas(factoryId: '');
      }
      if (!mounted) return;
      setState(() => _productionAreaMaster = areas);
    } catch (_) {
      // Falls back to the areas discovered on devices.
    }
    if (mounted) setState(() => _isLoadingProductionAreas = false);
  }

  Future<List<Map<String, String>>> _getProductionAreas({required String factoryId}) async {
    final qp = <String, String>{if (factoryId.isNotEmpty) 'factory_id': factoryId};
    final uri = Uri.parse('${AppConfig.dataApiBaseSafe}/productionAreas')
        .replace(queryParameters: qp.isEmpty ? null : qp);
    final res = await http
        .get(uri, headers: AppConfig.headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const [];
    final decoded = json.decode(res.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => {
              'id': e['id']?.toString() ?? '',
              'name': e['name']?.toString() ?? '',
              // Kept so an area can be resolved back to the plant that owns it,
              // which is how the production-area filter finds the configuration
              // an existing centre is already saved under.
              'factory_id':
                  (e['factory_id'] ?? e['company_id'] ?? '').toString(),
            })
        .where((e) => (e['name'] ?? '').isNotEmpty)
        .toList();
  }

  /// Devices offered by the mapping dropdowns, narrowed to the selected
  /// production area. Devices with no area recorded are kept so unclassified
  /// meters never become unmappable. A device already saved on a widget stays
  /// selectable regardless — [_DeviceDropdown] re-adds an out-of-list value —
  /// so switching area hides options without discarding existing mappings.
  List<String> get _devicesInScope {
    if (_selectedProductionArea.isEmpty) return _devices;
    return _devices.where((d) {
      final area = _deviceProductionAreas[d];
      return area == null || area.isEmpty || area == _selectedProductionArea;
    }).toList();
  }

  // ── Branding ──────────────────────────────────────────────────────────────
  /// The logo shown in the top-left badge. Separate from the aerial photo:
  /// that is the backdrop behind the map, this is the client's own mark. Until
  /// now the badge drew two letters taken from the organisation name, which is
  /// a stand-in for a logo rather than a logo.
  /// The five summary panels, each reading the pins rather than a device of
  /// its own. Seeded with what the dashboard already draws, so a config that
  /// has never been touched renders exactly as before.
  List<_PanelSpec> _panels = defaultPanelSpecs();

  /// A logo can also be given as a link. Uploading needs Firebase Storage to
  /// accept the write, and when it does not the failure is invisible from the
  /// settings page — a pasted URL always works and costs nothing to support.
  final _logoUrlCtrl = TextEditingController();

  Uint8List? _brandingLogoBytes;
  String? _brandingLogoExtension;
  String _brandingLogoName = '';
  String? _existingLogoUrl;
  String? _brandingLogoError;
  bool _isUploadingLogo = false;

  Uint8List? _brandingPhotoBytes;
  String _brandingPhotoName = '';
  String? _brandingPhotoExtension;
  bool _isUploadingPhoto = false;
  String? _brandingPhotoError;
  final ImagePicker _imagePicker = ImagePicker();

  static const int _maxImageSizeBytes = 5 * 1024 * 1024;
  static const List<String> _allowedPhotoExtensions = ['jpg', 'jpeg', 'png'];

  /// The two lines across the top of the live dashboard that used to be
  /// written into the code: the strapline under the org name, and the centre
  /// title. Editable so a new site does not need a release to be named.
  /// Free-text organisation name, used when the branding dropdown is set to
  /// "Custom…". Without it that option saved the literal string, so the live
  /// header read "CUSTOM…" with a "C" in the logo badge.
  final _customBrandingCtrl = TextEditingController();

  final _topBarSubLabelCtrl = TextEditingController();
  final _dashTitleCtrl = TextEditingController();

  /// Where the centre card sits on the group map, as percentages. Blank keeps
  /// its built-in place.
  final _heroXCtrl = TextEditingController();
  final _heroYCtrl = TextEditingController();

  /// What the centre card shows and how large it is drawn. Unconfigured
  /// (the default) means the card keeps its original built-in layout.
  HeroCardConfig _heroCardConfig = const HeroCardConfig();

  final TextEditingController _buildingLabelCtrl = TextEditingController();
  String _topBarBranding = '';
  /// The dropdown entry that means "type your own".
  static const String _kCustomBranding = 'Custom…';

  static const List<String> _brandingOptions = [
    'Thong Guan Group',
    'Danapac Sdn Bhd',
    'Intech Group',
    'Custom…',
  ];

  // ── Sections (initialised in _pecc_sections.dart) ─────────────────────────
  // NOTE: NOT final — _reinitSections() reassigns this after the plant is
  // matched (e.g. Lot 237, Lot 48) so the correct section layout is shown.
  late List<_Section> _sections;

  // ── PIN channel mappings (initialised in _pecc_sections.dart) ────────────
  List<_PinMapping> _pins = [];

  // ── Factory Overview (Block B) device groups + card filters ──────────────
  List<_FoDeviceGroup> _foGroups = [];
  List<_FoCardFilter> _foCards = [];

  /// Widget mappings from a previous layout that this layout cannot render.
  /// Carried through save untouched so switching layouts never destroys them.
  List<Map<String, dynamic>> _legacySections = [];

  // ── TNB site options for DATA SCOPE dropdown ─────────────────────────────
  List<Map<String, String>> _tnbSiteOptions = [];
  bool _isLoadingSites = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initSections();
    if (_usesMeterGroupLayout) {
      _initFoFilters();
    }
    _fetchDevices();
    _init();
  }

  /// Loads plants first (so an initialPlantName from the nav can be matched to
  /// a plant id), then loads that factory's config.
  Future<void> _init() async {
    await _fetchPlants();
    // After plants resolve, _selectedPlantId is known, so areas can be scoped.
    _fetchProductionAreas();
    await _fetchTnbSiteOptions();
    if (mounted) _loadConfig();
  }

  @override
  void dispose() {
    _buildingLabelCtrl.dispose();
    for (final p in _panels) {
      p.dispose();
    }
    _logoUrlCtrl.dispose();
    _customBrandingCtrl.dispose();
    _topBarSubLabelCtrl.dispose();
    _dashTitleCtrl.dispose();
    _heroXCtrl.dispose();
    _heroYCtrl.dispose();
    for (final p in _pins) { p.dispose(); }
    for (final sec in _sections) {
      for (final w in sec.widgets) {
        w.dispose();
      }
    }
    super.dispose();
  }

  // ── Computed counts (includes 3 branding items) ───────────────────────────

  bool get _photoMapped => _brandingPhotoBytes != null || (_existingPhotoUrl != null && _existingPhotoUrl!.isNotEmpty);
  bool get _labelMapped => _buildingLabelCtrl.text.trim().isNotEmpty;

  /// The organisation name actually written to configuration. "Custom…" is a
  /// prompt, not a name, so it never reaches the dashboard.
  String get _resolvedBranding => _topBarBranding == _kCustomBranding
      ? _customBrandingCtrl.text.trim()
      : _topBarBranding;
  bool get _orgMapped => _topBarBranding.isNotEmpty;

  int get _brandingMappedCount => (_photoMapped ? 1 : 0) + (_labelMapped ? 1 : 0) + (_orgMapped ? 1 : 0);

  int get _totalWidgets =>
      _sections.where((sec) => sec.title != 'Cost Drivers (Left Panel)').fold(0, (s, sec) => s + sec.widgets.length) + 3 + _pins.length;
  int get _mappedWidgets =>
      _sections.where((sec) => sec.title != 'Cost Drivers (Left Panel)').fold(0, (s, sec) => s + sec.mappedCount) +
      _brandingMappedCount +
      _pins.where((p) => p.isMapped).length;
  int get _unmappedWidgets => _totalWidgets - _mappedWidgets;

  // ── API — plants ───────────────────────────────────────────────────────────

  Future<void> _fetchPlants() async {
    if (mounted) setState(() => _isLoadingPlants = true);
    try {
      final res = await http
          .get(
            Uri.parse('${AppConfig.dataApiBaseSafe}/factory'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        final List<dynamic> data = json.decode(res.body);
        final plants = data
            .where((e) => (e['id']?.toString() ?? '').isNotEmpty && (e['name']?.toString() ?? '').isNotEmpty)
            .map((e) => {'id': e['id'].toString(), 'name': e['name'].toString()})
            .toList();
        setState(() {
          _plants = plants.cast<Map<String, dynamic>>();
          // If the nav opened this page pre-scoped to a factory (e.g. the
          // "Lot 237 Energy Command Center" entry passes initialPlantName),
          // match it by name → its id. Otherwise stay on '' ("All plants"
          // group) and let the user pick.
          final initial = widget.initialPlantName?.trim() ?? '';
          if (initial.isNotEmpty && _selectedPlantId.isEmpty) {
            // A command centre scoped to a production area sits under its
            // parent plant: Lot 237 B is plant "Lot 237", area "Block B
            // Production Area" — not a plant called "Lot 237 Block B". The
            // config still saves under the ECC identity (_eccIdentity), so
            // pointing the filters at the parent cannot collide with Lot 237.
            final defaults = _filterDefaultsFor(initial);
            final plantName = defaults.$1;
            final areaName = defaults.$2;

            final match = _plants.firstWhere(
              (p) => (p['name'] as String).trim().toLowerCase() == plantName.toLowerCase(),
              orElse: () => const {},
            );
            if (match.isNotEmpty) {
              _selectedPlantId = match['id'] as String;
            } else {
              _selectedPlantId = plantName;
            }
            if (areaName.isNotEmpty) _selectedProductionArea = areaName;
            _reinitSections();
          }
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingPlants = false);
  }

  /// Maps a command centre identity to the (plant, production area) its filter
  /// bar should open on. Block-level centres resolve to their parent plant plus
  /// their own area; plant-level centres resolve to themselves with no area.
  (String, String) _filterDefaultsFor(String identity) {
    switch (identity.trim().toLowerCase()) {
      case 'lot 237 block b':
      case 'lot237blockb':
      case 'block b':
        return ('Lot 237', 'Block B Production Area');
      default:
        return (identity, '');
    }
  }

  // ── API — devices ─────────────────────────────────────────────────────────

  Future<void> _fetchDevices() async {
    if (mounted) setState(() => _isLoadingDevices = true);
    final ids = <String>{};
    await Future.wait([
      // 1) Device IDs registered in Master Facilities Setting — the source of
      //    truth for linkable devices. A newly registered ID (e.g. a solar
      //    meter) is selectable here even before any SQL data exists; once
      //    SQL is set up its data shows on the kanban automatically.
      () async {
        try {
          final facilities = await FacilityService.getFacilities();
          for (final f in facilities) {
            final id = f.meterId.trim();
            if (id.isNotEmpty && id != '-') {
              ids.add(id);
              // Build display name: prefer meterName, then equipmentNameId, then machineName.
              final meterName  = f.meterName.trim();
              final equipName  = f.equipmentNameId.trim();
              final machineName = f.machineName.trim();
              final preferred = meterName.isNotEmpty && meterName != '-'
                  ? meterName
                  : equipName.isNotEmpty && equipName != '-'
                      ? equipName
                      : machineName.isNotEmpty && machineName != '-'
                          ? machineName
                          : '';
              if (preferred.isNotEmpty) {
                _deviceDisplayNames[id] = preferred;
              }
              // PRODUCTION AREA is FacilityData.zone — the field Master
              // Facilities fills from the /productionAreas master list and
              // labels "Zone / Production Area". FacilityData.productionArea is
              // the production LINE (from /productionLines) despite its name;
              // filtering on it linked this dropdown to the wrong dimension.
              final area = f.zone.trim();
              if (area.isNotEmpty && area != '-') {
                _deviceProductionAreas[id] = area;
              }
            }
          }
        } catch (_) {}
      }(),
      // 2) Equipment master list (same IDs used in Energy Data Logger).
      () async {
        try {
          final equipments = await FacilityService.getEquipments();
          for (final e in equipments) {
            final id = e.equipmentId.trim();
            if (id.isNotEmpty && id != '-') ids.add(id);
          }
        } catch (_) {}
      }(),
      // 3) TNB Meter Setting DPM tags (e.g. Lot 237 → VDPM002) — Bill Simulator source.
      () async {
        try {
          final uid = AppStateNotifier.instance.uid ?? '';
          final qp = uid.isNotEmpty ? '?userId=${Uri.encodeQueryComponent(uid)}' : '';
          final res = await http
              .get(
                Uri.parse('${AppConfig.dataApiBaseSafe}/tnbMeters$qp'),
                headers: AppConfig.headers,
              )
              .timeout(const Duration(seconds: 10));
          if (res.statusCode == 200) {
            for (final raw in json.decode(res.body) as List<dynamic>) {
              if (raw is! Map) continue;
              for (final key in ['influxDbTag', 'meterCode', 'deviceId', 'device_id']) {
                final id = raw[key]?.toString().trim() ?? '';
                if (id.isNotEmpty && id != '-') ids.add(id);
              }
            }
          }
        } catch (_) {}
      }(),
      // 4) Devices already reporting to MySQL — kept so legacy mappings whose
      //    ID isn't registered in Master Facilities keep working.
      () async {
        try {
          final res = await http
              .get(
                Uri.parse('${AppConfig.dataApiBaseSafe}/energyDetails/devices'),
                headers: AppConfig.headers,
              )
              .timeout(const Duration(seconds: 10));
          if (res.statusCode == 200) {
            final List<dynamic> data = json.decode(res.body);
            for (final d in data) {
              final id = (d is Map ? d['device_id'] : null)?.toString() ?? '';
              if (id.isNotEmpty) ids.add(id);
            }
          }
        } catch (_) {}
      }(),
    ]);
    if (mounted) {
      setState(() {
        _devices = ids.toList()..sort();
        _isLoadingDevices = false;
        if (_usesMeterGroupLayout) {
          if (_foGroups.isEmpty || _foCards.isEmpty) {
            _initFoFilters();
          } else if (_devices.isNotEmpty) {
            // Keep "All Block B" in sync with real device list when it was empty.
            for (final g in _foGroups) {
              if (g.id == 'g_all' && g.members.isEmpty) {
                g.members = List.of(_devices);
              }
            }
            // Seed Production / Utilities splits if still empty.
            for (final g in _foGroups) {
              if (g.id == 'g_prod' && g.members.isEmpty) {
                g.members = _devices.take(math.min(18, _devices.length)).toList();
              }
              if (g.id == 'g_util' && g.members.isEmpty && _devices.length > 18) {
                g.members = _devices.sublist(18, math.min(28, _devices.length));
              }
            }
          }
        }
      });
    }
  }

  // ── API — TNB site options (for group pin DATA SCOPE dropdown) ───────────

  Future<void> _fetchTnbSiteOptions() async {
    if (mounted) setState(() => _isLoadingSites = true);
    try {
      final meters = await TnbMeterService.fetchMeters();
      if (!mounted) return;
      final opts = <Map<String, String>>[];
      final seenIds = <String>{};
      for (final m in meters) {
        final code = m.meterCode.trim();
        final influxTag = m.influxDbTag.trim();
        final label = m.meterLabel.trim().isNotEmpty ? m.meterLabel.trim() : code;

        // Primary key: meterCode if non-empty, else influxDbTag / id
        final primaryId = code.isNotEmpty ? code : (influxTag.isNotEmpty ? influxTag : m.id);

        if (primaryId.isNotEmpty && !seenIds.contains(primaryId)) {
          seenIds.add(primaryId);
          final displayLabel = influxTag.isNotEmpty && influxTag != '-' && influxTag != primaryId
              ? '[$primaryId / $influxTag] — $label'
              : '[$primaryId] — $label';
          opts.add({
            'id': primaryId,
            'label': displayLabel,
            'dpmId': primaryId,
            'dbId': m.id,
          });
        }

        // Also add influxDbTag option if different and non-empty
        if (influxTag.isNotEmpty && influxTag != '-' && influxTag != primaryId && !seenIds.contains(influxTag)) {
          seenIds.add(influxTag);
          opts.add({
            'id': influxTag,
            'label': '[$influxTag] — $label',
            'dpmId': influxTag,
            'dbId': m.id,
          });
        }
      }
      // Sort by DPM ID for easy lookup
      opts.sort((a, b) => a['dpmId']!.compareTo(b['dpmId']!));
      setState(() => _tnbSiteOptions = opts);
    } catch (_) {}
    if (mounted) setState(() => _isLoadingSites = false);
  }

  // The config is keyed by factory NAME (e.g. "Lot 237"), not the factory's
  // dynamic doc id — so the setting and the dashboard viewer (which only
  // knows the name from the nav) agree on the same storage key.
  String get _selectedPlantName {
    if (_selectedPlantId.isNotEmpty) {
      final m = _plants.firstWhere((p) => p['id'] == _selectedPlantId, orElse: () => const <String, dynamic>{});
      final name = (m['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) return name;
    }
    return widget.initialPlantName?.trim() ?? '';
  }

  /// True once an admin has picked a plant from the PLANT dropdown, as opposed
  /// to the page simply opening on whatever the nav passed in.
  bool _plantPickedFromFilter = false;

  /// Identity of the command centre being edited.
  ///
  /// The nav decides which centre opens; the PLANT dropdown then switches
  /// between them, so one settings page sets up every production lot and the
  /// filter is how you choose which.
  ///
  /// This used to ignore the dropdown on purpose, to stop one centre's layout
  /// being saved over another's document. That risk is real but it comes from
  /// changing the key without changing what is on screen — so switching plants
  /// now reloads that plant's own configuration and rebuilds its sections
  /// before anything can be saved. What you see and what Save writes are the
  /// same centre.
  String get _eccIdentity {
    // On a block centre the PRODUCTION AREA dropdown is what chooses which
    // dashboard is being set up — the plant filter is gone from that screen.
    if (_areaPickedFromFilter) {
      final key = _centreKeyForArea(_selectedProductionArea);
      if (key.isNotEmpty) return key;
    }
    if (_plantPickedFromFilter) {
      final picked = _selectedPlantName.trim();
      if (picked.isNotEmpty) return picked;
    }
    final initial = widget.initialPlantName?.trim() ?? '';
    return initial.isNotEmpty ? initial : _selectedPlantName;
  }

  /// True once an admin has chosen a production area from the filter.
  bool _areaPickedFromFilter = false;

  /// Which stored configuration a production area belongs to.
  ///
  /// Every existing centre is saved under its plant's name — "Lot 237 Block B"
  /// holds twenty-three mapped machines today. An area that is the only one in
  /// its plant therefore keeps using the plant's key, so choosing it here opens
  /// the configuration that already exists rather than a blank one beside it.
  /// Only where a plant holds several areas (LOT 53) does each area need a key
  /// of its own, and there is nothing saved under those yet to strand.
  String _centreKeyForArea(String areaName) {
    final name = areaName.trim();
    if (name.isEmpty) return '';
    final row = _productionAreaMaster.firstWhere(
      (a) => (a['name'] ?? '').trim() == name,
      orElse: () => const <String, String>{},
    );
    final plantId = (row['factory_id'] ?? '').trim();
    if (plantId.isEmpty) return name;
    final siblings = _productionAreaMaster
        .where((a) => (a['factory_id'] ?? '').trim() == plantId)
        .length;
    if (siblings != 1) return name;
    final plant = _plants.firstWhere(
      (p) => p['id'] == plantId,
      orElse: () => const <String, dynamic>{},
    );
    final plantName = (plant['name'] as String?)?.trim() ?? '';
    return plantName.isNotEmpty ? plantName : name;
  }

  // ── API — config load ─────────────────────────────────────────────────────

  Future<void> _loadConfig() async {
    final uid = AppStateNotifier.instance.uid ?? '';
    if (uid.isEmpty) return;
    final loadVersion = ++_configLoadVersion;
    if (mounted) setState(() => _isLoadingConfig = true);
    try {
      // Scope to the selected factory by name. Empty → the group / "All
      // plants" config (backward compatible); a name → that factory's own
      // saved config (e.g. Lot 237).
      final plantKey = _eccIdentity;
      final qp = plantKey.isNotEmpty
          ? '?plantId=${Uri.encodeQueryComponent(plantKey)}'
          : '';
      final res = await http
          .get(
            Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/plant-energy-command-center/$uid$qp'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted || loadVersion != _configLoadVersion) return;
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        if (body['exists'] == true && body['settings'] != null) {
          _applyConfig(body['settings'] as Map<String, dynamic>);
        } else {
          // This account has no config of its own for this factory yet.
          // Seed the editor from whichever admin's config the live
          // dashboard itself would fall back to, so Settings shows the same
          // thing the account is already seeing — not a blank template. This
          // is read-only seeding: nothing is written until Save, and Save
          // always writes under THIS account's own uid, so from that point
          // on this account's edits are its own and never overwrite, or get
          // overwritten by, anyone else's.
          final fallbackUid = await _findFallbackAdminUid();
          var seeded = false;
          if (fallbackUid != null && fallbackUid != uid) {
            try {
              final fbRes = await http
                  .get(
                    Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/plant-energy-command-center/$fallbackUid$qp'),
                    headers: AppConfig.headers,
                  )
                  .timeout(const Duration(seconds: 10));
              if (!mounted || loadVersion != _configLoadVersion) return;
              if (fbRes.statusCode == 200) {
                final fbBody = json.decode(fbRes.body) as Map<String, dynamic>;
                if (fbBody['exists'] == true && fbBody['settings'] != null) {
                  _applyConfig(fbBody['settings'] as Map<String, dynamic>);
                  seeded = true;
                }
              }
            } catch (_) {}
          }
          if (!seeded) _resetConfig();
        }
      }
    } catch (_) {}
    if (mounted && loadVersion == _configLoadVersion) {
      setState(() => _isLoadingConfig = false);
    }
  }

  /// Mirrors kanban_dashboard_widget.dart's own _findFallbackAdminUid(): the
  /// userId behind the most recently created row in kanban-settings/list —
  /// the same account the live dashboard itself falls back to for a viewer
  /// with no config of their own.
  Future<String?> _findFallbackAdminUid() async {
    try {
      final res = await http
          .get(
            Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings/list'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? [];
      for (final raw in data) {
        final t = raw as Map<String, dynamic>;
        final ownerUid = t['userId']?.toString();
        if (ownerUid != null && ownerUid.isNotEmpty) return ownerUid;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Clears all widget mappings + branding + pins — used when switching
  /// factory so stale values don't linger.
  void _resetConfig() {
    for (final section in _sections) {
      for (final mapping in section.widgets) {
        mapping.selectedDevice = '';
        mapping.selectedField  = '';
        mapping.xCtrl.text     = '';
        mapping.yCtrl.text     = '';
        for (final m in mapping.metrics) {
          m.dispose();
        }
        mapping.metrics = [];
        mapping.expanded = false;
        mapping.labelCtrl.text = mapping.label;
      }
    }
    for (final p in _pins) {
      p.displayNameCtrl.text  = p.defaultLabel;
      p.selectedSiteId        = '';
      p.selectedSiteLabel     = '';
      p.selectedMetric        = '';
      for (final m in p.metrics) {
        m.dispose();
      }
      p.metrics = [];
      p.expanded = false;
      p.selectedSolarDevice = '';
      p.xCtrl.text = '';
      p.yCtrl.text = '';
    }
    if (_usesMeterGroupLayout) _resetFoFilters();
    _buildingLabelCtrl.text = '';
    _customBrandingCtrl.text = '';
    _topBarSubLabelCtrl.text = '';
    _dashTitleCtrl.text      = '';
    _heroXCtrl.text          = '';
    _heroYCtrl.text          = '';
    _heroCardConfig          = const HeroCardConfig();
    _topBarBranding         = '';
    for (final p in _panels) {
      p.dispose();
    }
    _panels = defaultPanelSpecs();
    _brandingLogoBytes      = null;
    _logoUrlCtrl.text       = '';
    _brandingLogoName       = '';
    _existingLogoUrl        = null;
    _brandingLogoError      = null;
    _brandingPhotoBytes     = null;
    _brandingPhotoName      = '';
    // The floor photo has to go with the rest, or switching plants leaves the
    // previous lot's floor plan sitting behind the new lot's form.
    _existingPhotoUrl       = null;
    if (mounted) setState(() {});
  }

  /// Called when the PLANT dropdown changes.
  ///
  /// The dropdown chooses which command centre is being edited, so the form is
  /// emptied and that plant's own configuration is loaded in its place. A plant
  /// nobody has set up therefore shows blank fields rather than the last
  /// plant's values, which would otherwise be saved onto it.
  /// Switches the block centre being edited to another production area.
  ///
  /// Mirrors [_onPlantChanged]: empty the form, rebuild the sections, then load
  /// that area's own configuration, so what is on screen and what Save writes
  /// are always the same dashboard.
  void _onProductionAreaCentreChanged(String areaName) {
    setState(() {
      _selectedProductionArea = areaName;
      _areaPickedFromFilter = true;
    });
    _reinitSections();
    if (_usesMeterGroupLayout) {
      _initFoFilters();
    } else {
      _foGroups = [];
      _foCards = [];
    }
    _resetConfig();
    _loadConfig();
  }

  void _onPlantChanged(String plantId) {
    if (plantId == _selectedPlantId) return;
    setState(() {
      _selectedPlantId = plantId;
      // From here the dropdown names the centre being edited, not just a
      // filter over the current one.
      _plantPickedFromFilter = true;
      // Areas belong to a plant, so the previous selection cannot carry over.
      _selectedProductionArea = '';
      _productionAreaMaster = [];
    });
    _fetchProductionAreas();

    _reinitSections();
    if (_usesMeterGroupLayout) {
      _initFoFilters();
    } else {
      _foGroups = [];
      _foCards = [];
    }
    _resetConfig();
    _loadConfig();
  }

  void _applyConfig(Map<String, dynamic> settings) {
    // Standardising every centre on the meter-group layout means a config saved
    // under an older layout (e.g. Lot 237's 39 hero/plant-total widget
    // mappings) has keys this layout does not render. Those entries would
    // otherwise be dropped from the document on the next save. Stash them and
    // write them back untouched, so reverting _usesMeterGroupLayout restores
    // the old screen with its mappings intact.
    final liveKeys = <String>{
      for (final s in _sections) for (final w in s.widgets) w.key,
    };
    final carried = <Map<String, dynamic>>[];
    for (final sec in (settings['sections'] as List<dynamic>? ?? [])) {
      if (sec is! Map) continue;
      final unknown = (sec['widgets'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .where((w) => !liveKeys.contains(w['key']?.toString() ?? ''))
          .toList();
      if (unknown.isNotEmpty) {
        carried.add({
          'title': sec['title']?.toString() ?? '',
          'widgets': unknown,
        });
      }
    }
    // Merge with anything already parked by a previous save — read from both
    // the top level and the branding nest, since only the latter survives the
    // current Cloud Function.
    final parked = <dynamic>[
      ...(settings['legacySections'] as List<dynamic>? ?? const []),
      ...(((settings['branding'] as Map<String, dynamic>?)?['legacySections']
              as List<dynamic>?) ??
          const []),
    ];
    for (final sec in parked) {
      if (sec is Map && !carried.any((c) => c['title'] == sec['title'])) {
        carried.add(Map<String, dynamic>.from(sec));
      }
    }
    _legacySections = carried;

    for (final sec in (settings['sections'] as List<dynamic>? ?? [])) {
      for (final w in (sec['widgets'] as List<dynamic>? ?? [])) {
        final key    = w['key']?.toString()            ?? '';
        final label  = w['label']?.toString()          ?? '';
        final device = w['selectedDevice']?.toString() ?? '';
        final field  = w['selectedField']?.toString()  ?? '';

        // A machine added from this screen and saved has no built-in mapping
        // to land on: the defaults only describe consumer[0]..consumer[5].
        // Without this the saved entry matched nothing and was dropped, so
        // Add machine looked like it worked until the page came back — and the
        // next save wrote the shortened list back, losing the machine for good.
        if (key.startsWith('consumer[') &&
            !_sections.any((sec) => sec.widgets.any((m) => m.key == key))) {
          for (final host in _sections) {
            if (!host.canAddMachines) continue;
            host.widgets.add(_WidgetMapping(
              key: key,
              label: 'Machine #${host.widgets.length + 1}',
              locationKey: 'Machine #${host.widgets.length + 1}',
              icon: Icons.precision_manufacturing,
              iconBg: const Color(0x1AF43F5E),
              iconColor: const Color(0xFFF43F5E),
              unit: 'kW',
              // Field list comes from a sibling, so the new row offers the
              // same choices as the machines that shipped with the section.
              availableFields: host.widgets.isNotEmpty
                  ? host.widgets.first.availableFields
                  : const [],
            ));
            break;
          }
        }

        for (final section in _sections) {
          for (final mapping in section.widgets) {
            if (mapping.key == key) {
              // Keep human titles — ignore saved labels that are device IDs
              // or technical keys like consumer[0].
              final looksTechnical = RegExp(r'^[A-Za-z_]+\[\d+\]$').hasMatch(label);
              if (label.isNotEmpty && !looksTechnical) {
                mapping.label = label;
                mapping.labelCtrl.text = label;
              }
              mapping.selectedDevice = device;
              mapping.selectedField  = field;
              mapping.xCtrl.text = w['xPct']?.toString() ?? '';
              mapping.yCtrl.text = w['yPct']?.toString() ?? '';
              for (final m in mapping.metrics) {
                m.dispose();
              }
              mapping.metrics = ((w['metrics'] as List<dynamic>?) ?? [])
                  .whereType<Map>()
                  .map((m) => _PinMetric.fromJson(m.cast<String, dynamic>()))
                  .where((m) => m.isMapped)
                  .take(kMaxPinMetrics)
                  .toList();
            }
          }
        }
      }
    }
    // Restore group pin channel mappings
    for (final pd in (settings['pins'] as List<dynamic>? ?? [])) {
      final key     = pd['key']?.toString()            ?? '';
      final dname   = pd['displayName']?.toString()    ?? '';
      final siteId  = pd['selectedSiteId']?.toString() ?? '';
      final siteLbl = pd['selectedSiteLabel']?.toString() ?? '';
      final metric  = pd['selectedMetric']?.toString() ?? '';

      // A pin the built-in list does not know about was added from this screen
      // and saved. Without this it was matched against the fixed six, found
      // nothing, and vanished on reload — so adding a cost driver appeared to
      // work until the page came back.
      if (!_pins.any((p) => p.key == key) && key.startsWith('pin[')) {
        final idx = int.tryParse(key.substring(4, key.length - 1));
        if (idx != null) {
          _pins.add(_PinMapping(
            key: key,
            pinIndex: idx,
            defaultLabel: dname.isNotEmpty ? dname : 'Cost Driver ${idx + 1}',
            isRemovable: true,
          ));
        }
      }

      for (final pin in _pins) {
        if (pin.key == key) {
          final isStaleCostDriver4 = dname.toLowerCase().contains('cost driver 4');
          if (dname.isNotEmpty && !isStaleCostDriver4) {
            pin.displayNameCtrl.text = dname;
          } else {
            pin.displayNameCtrl.text = pin.defaultLabel;
          }
          pin.selectedSiteId    = siteId;
          pin.selectedSiteLabel = siteLbl;
          pin.selectedMetric    = metric;

          // Card metrics. Absent in configs saved before pins could show more
          // than cost and energy, and left empty in that case so an existing
          // dashboard renders exactly as it did.
          for (final m in pin.metrics) {
            m.dispose();
          }
          pin.selectedSolarDevice = pd['solarDevice']?.toString() ?? '';
          pin.xCtrl.text = pd['xPct']?.toString() ?? '';
          pin.yCtrl.text = pd['yPct']?.toString() ?? '';
          pin.metrics = ((pd['metrics'] as List<dynamic>?) ?? [])
              .whereType<Map>()
              .map((m) => _PinMetric.fromJson(m.cast<String, dynamic>()))
              .where((m) => m.isMapped)
              .take(kMaxPinMetrics)
              .toList();
        }
      }
    }
    // Panels. Anything missing keeps its default, so a config saved before
    // panels were configurable is read without loss.
    final brandingForPanels =
        settings['branding'] as Map<String, dynamic>? ?? const {};
    final savedPanels = settings['panels'] as Map<String, dynamic>? ??
        (brandingForPanels['panels'] as Map<String, dynamic>? ?? {});
    if (savedPanels.isNotEmpty) {
      for (final spec in _panels) {
        final rows = savedPanels[spec.id] as List<dynamic>? ?? const [];
        if (rows.isEmpty) continue;
        final byKey = {for (final c in spec.cards) c.key: c};
        final rebuilt = <_PanelCard>[];
        for (final r in rows.whereType<Map>()) {
          final j = r.cast<String, dynamic>();
          final fallback = byKey[j['key']?.toString()] ?? spec.cards.first;
          rebuilt.add(_PanelCard.fromJson(j, fallback));
        }
        if (rebuilt.isNotEmpty) {
          spec.dispose();
          spec.cards = rebuilt;
        }
      }
    }

    final branding = settings['branding'] as Map<String, dynamic>? ?? {};
    _buildingLabelCtrl.text = branding['buildingLabel']?.toString() ?? '';
    // A saved name that is not one of the presets was typed by hand, so put
    // the dropdown on Custom and show the text back rather than losing it.
    final savedBranding = branding['topBarBranding']?.toString() ?? '';
    if (savedBranding.isNotEmpty && !_brandingOptions.contains(savedBranding)) {
      _customBrandingCtrl.text = savedBranding;
    }
    _topBarSubLabelCtrl.text = branding['topBarSubLabel']?.toString() ?? '';
    _dashTitleCtrl.text = branding['dashTitle']?.toString() ?? '';
    _heroXCtrl.text = branding['heroXPct']?.toString() ?? '';
    _heroYCtrl.text = branding['heroYPct']?.toString() ?? '';
    _heroCardConfig = HeroCardConfig.fromJson(branding['heroCard'] as Map<String, dynamic>?);
    _topBarBranding = _brandingOptions.contains(savedBranding)
        ? savedBranding
        : (savedBranding.isEmpty ? '' : _kCustomBranding);
    final logoUrl = branding['logoUrl']?.toString() ?? '';
    if (logoUrl.isNotEmpty) {
      _existingLogoUrl = logoUrl;
      _brandingLogoName = logoUrl.split('/').last.split('?').first;
      _logoUrlCtrl.text = logoUrl;
    }
    final photoUrl = branding['photoUrl']?.toString() ?? '';
    if (photoUrl.isNotEmpty) {
      _existingPhotoUrl = photoUrl;
      _brandingPhotoName = photoUrl.split('/').last.split('?').first;
    } else {
      _existingPhotoUrl = null;
    }
    if (_usesMeterGroupLayout) {
      if (_foCards.isEmpty) _initFoFilters();
      _applyFoFiltersConfig(settings);
    }
    if (mounted) setState(() {});
  }

  String? _existingPhotoUrl;

  // ── API — config save ─────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _savingStatus = 'Preparing…';
      _saveMessage = null;
      _saveSuccess = false;
    });

    try {
      // Phase 1 — upload photo if a new one was picked, or retain existing photo
      String? photoUrl = _existingPhotoUrl;
      if (_brandingPhotoBytes != null) {
        setState(() => _savingStatus = 'Uploading photo…');
        final uploaded = await _uploadBrandingPhotoToFirebase();
        if (uploaded != null && uploaded.isNotEmpty) {
          photoUrl = uploaded;
          _existingPhotoUrl = uploaded;
        }
      }

      // A typed link wins over a previously uploaded file, since typing one is
      // the more deliberate act.
      String? logoUrl = _logoUrlCtrl.text.trim().isNotEmpty
          ? _logoUrlCtrl.text.trim()
          : _existingLogoUrl;
      if (_brandingLogoBytes != null) {
        setState(() => _savingStatus = 'Uploading logo…');
        final uploaded = await _uploadBrandingLogoToFirebase();
        if (uploaded != null && uploaded.isNotEmpty) {
          logoUrl = uploaded;
          _existingLogoUrl = uploaded;
        }
      }

      // Phase 2 — POST config
      setState(() => _savingStatus = 'Saving configuration…');

      final sectionsPayload = _sections
          .map((sec) => {
                'title': sec.title,
                'widgets': sec.widgets
                    .map((w) => {
                          'key': w.key,
                          'label': w.labelCtrl.text.trim(),
                          'selectedDevice': w.selectedDevice,
                          'selectedField': w.selectedField,
                          if (w.xCtrl.text.trim().isNotEmpty)
                            'xPct': w.xCtrl.text.trim(),
                          if (w.yCtrl.text.trim().isNotEmpty)
                            'yPct': w.yCtrl.text.trim(),
                          'metrics':
                              w.metrics.map((m) => m.toJson()).toList(),
                        })
                    .toList(),
              })
          .toList();

      final pinsPayload = _pins.map((p) => {
            'key':               p.key,
            'displayName':       p.displayNameCtrl.text.trim(),
            'selectedSiteId':    p.selectedSiteId,
            'selectedSiteLabel': p.selectedSiteLabel,
            'selectedMetric':    p.selectedMetric,
            'solarDevice':       p.selectedSolarDevice,
            'metrics':           p.metrics.map((m) => m.toJson()).toList(),
            // Blank means "keep the built-in position", so an untouched pin is
            // not pinned to a number it never had.
            if (p.xCtrl.text.trim().isNotEmpty) 'xPct': p.xCtrl.text.trim(),
            if (p.yCtrl.text.trim().isNotEmpty) 'yPct': p.yCtrl.text.trim(),
            'removable':         p.isRemovable,
          }).toList();

      final panelsPayload = <String, dynamic>{
        for (final p in _panels)
          p.id: p.cards.map((c) => c.toJson()).toList(),
      };

      final brandingPayload = <String, dynamic>{
        'panels': panelsPayload,
        'buildingLabel':  _buildingLabelCtrl.text.trim(),
        'topBarBranding': _resolvedBranding,
        'topBarSubLabel': _topBarSubLabelCtrl.text.trim(),
        'dashTitle':      _dashTitleCtrl.text.trim(),
        // Sent empty too, for the same merge reason as the images below:
        // leaving them out would keep an old position after a reset.
        'heroXPct':       _heroXCtrl.text.trim(),
        'heroYPct':       _heroYCtrl.text.trim(),
        'heroCard':       _heroCardConfig.toJson(),
        // Always sent, empty included. The API merges branding, so a field left
        // out keeps whatever was there before — which meant "Remove logo" set
        // the value to nothing locally and then saved nothing, and the old
        // image came straight back on reload. An explicit empty string is what
        // actually clears it, confirmed against the endpoint.
        'logoUrl': logoUrl ?? '',
        'photoUrl': photoUrl ?? '',
      };

      final uid = AppStateNotifier.instance.uid ?? '';
      // Must hit the same function as _loadConfig (ui7) — plant-energy-command-center
      // isn't mounted on AppConfig.apiBase's function, which previously caused a
      // "Cannot POST" HTML 404 response that crashed json.decode with a FormatException.
      final body = <String, dynamic>{
        'sections': sectionsPayload,
        'pins':     pinsPayload,
        // Top-level for when the API learns about it, and nested under
        // branding because the Cloud Function destructures only the fields it
        // already knows — the same reason factoryOverview and legacySections
        // are nested. Sent top-level alone, this field is silently dropped.
        'panels':   panelsPayload,
        'branding': brandingPayload,
        'plantId':  _eccIdentity, // ECC identity — same key the viewer uses
      };
      // Mappings belonging to a layout this screen no longer renders. Written
      // back verbatim so a layout switch is reversible without data loss.
      // Nested inside branding because the Cloud Function destructures only
      // known top-level fields — the same reason factoryOverview is nested.
      // Top-level too, for if/when the API learns about it.
      if (_legacySections.isNotEmpty) {
        body['legacySections'] = _legacySections;
        brandingPayload['legacySections'] = _legacySections;
      }
      if (_usesMeterGroupLayout) {
        if (_foCards.isEmpty || _foGroups.isEmpty) {
          _initFoFilters();
        }
        // Ensure every card points at a real group before save.
        for (final c in _foCards) {
          if (!_foGroups.any((g) => g.id == c.groupId)) {
            c.groupId = _foGroups.isNotEmpty ? _foGroups.first.id : 'g_all';
          }
        }
        final groups = _foGroupsPayload();
        final cards = _foCardsPayload();
        // Top-level (for redeployed API) + nested under branding (works on current deploy).
        body['groups'] = groups;
        body['cards'] = cards;
        brandingPayload['factoryOverview'] = {
          'groups': groups,
          'cards': cards,
        };
      }
      final res = await http
          .post(
            Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/plant-energy-command-center/$uid'),
            headers: {...AppConfig.headers, 'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (res.statusCode == 200) {
        // Reload so Device Groups / Card Filters reflect what actually persisted
        // (nested under branding.factoryOverview on the current Cloud Function).
        await _loadConfig();
        if (!mounted) return;
        setState(() {
          _isSaving = false;
          _savingStatus = '';
          _saveSuccess = true;
          _saveMessage = 'Configuration saved successfully.';
        });
        widget.onSaved?.call();
        if (widget.embedded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.onApplyOverview?.call();
          });
        }
      } else {
        final body = json.decode(res.body) as Map<String, dynamic>;
        setState(() {
          _isSaving = false;
          _savingStatus = '';
          _saveSuccess = false;
          _saveMessage = body['error']?.toString() ?? 'Save failed (${res.statusCode}).';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _savingStatus = '';
          _saveSuccess = false;
          _saveMessage = 'Error: $e';
        });
      }
    }

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _saveMessage = null);
    });
  }

  // ── Photo — pick ──────────────────────────────────────────────────────────

  Future<void> _pickAndValidateBrandingPhoto() async {
    try {
      final XFile? picked = await _imagePicker.pickImage(source: ImageSource.gallery, imageQuality: 100);
      if (picked == null) return;
      final ext = picked.name.toLowerCase().split('.').last;
      if (!_allowedPhotoExtensions.contains(ext)) {
        setState(() => _brandingPhotoError = 'Only JPG and PNG images are allowed');
        return;
      }
      final bytes = await picked.readAsBytes();
      if (bytes.length > _maxImageSizeBytes) {
        setState(() => _brandingPhotoError = 'Image must be < 5 MB (got ${(bytes.length / 1048576).toStringAsFixed(2)} MB)');
        return;
      }
      setState(() {
        _brandingPhotoBytes = bytes;
        _brandingPhotoExtension = ext;
        _brandingPhotoName = picked.name;
        _brandingPhotoError = null;
      });
    } catch (e) {
      setState(() => _brandingPhotoError = 'Error picking image: $e');
    }
  }

  // ── Logo — pick and upload ────────────────────────────────────────────────

  Future<void> _pickBrandingLogo() async {
    try {
      final XFile? picked = await _imagePicker.pickImage(
          source: ImageSource.gallery, imageQuality: 100);
      if (picked == null) return;
      final ext = picked.name.toLowerCase().split('.').last;
      if (!_allowedPhotoExtensions.contains(ext)) {
        setState(() => _brandingLogoError = 'Only JPG and PNG images are allowed');
        return;
      }
      final bytes = await picked.readAsBytes();
      if (bytes.length > _maxImageSizeBytes) {
        setState(() => _brandingLogoError =
            'Image must be < 5 MB (got ${(bytes.length / 1048576).toStringAsFixed(2)} MB)');
        return;
      }
      setState(() {
        _brandingLogoBytes = bytes;
        _brandingLogoExtension = ext;
        _brandingLogoName = picked.name;
        _brandingLogoError = null;
      });
    } catch (e) {
      setState(() => _brandingLogoError = 'Error picking image: $e');
    }
  }

  Future<String?> _uploadBrandingLogoToFirebase() async {
    if (_brandingLogoBytes == null) return null;
    setState(() => _isUploadingLogo = true);
    try {
      final ext = _brandingLogoExtension ?? 'png';
      final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
      // Scoped by factory like the aerial photo, and under its own name so a
      // logo upload can never overwrite the backdrop.
      final plantSuffix = _eccIdentity.isNotEmpty
          ? '_${_eccIdentity.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}'
          : '';
      final fileName = 'kanban_logo_${AppConfig.clientId}$plantSuffix.$ext';
      final ref =
          FirebaseStorage.instance.ref().child('kanban_branding/$fileName');
      final snapshot = await ref
          .putData(_brandingLogoBytes!, SettableMetadata(contentType: contentType))
          .timeout(const Duration(seconds: 60),
              onTimeout: () => throw Exception('Upload timed out'));
      return await snapshot.ref.getDownloadURL();
    } on FirebaseException catch (e) {
      setState(() => _brandingLogoError = 'Firebase error: ${e.message}');
      return null;
    } catch (e) {
      setState(() => _brandingLogoError = 'Upload error: $e');
      return null;
    } finally {
      setState(() => _isUploadingLogo = false);
    }
  }

  // ── Photo — upload ────────────────────────────────────────────────────────

  Future<String?> _uploadBrandingPhotoToFirebase() async {
    if (_brandingPhotoBytes == null) return null;
    setState(() => _isUploadingPhoto = true);
    try {
      final ext = _brandingPhotoExtension ?? 'jpg';
      final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
      // Per-factory branding photo — scope the filename by the factory NAME
      // (the same key the config is stored under), so each factory keeps its
      // own distinct photo file and never collides with the group's. Empty
      // → the group photo.
      final plantSuffix = _eccIdentity.isNotEmpty
          ? '_${_eccIdentity.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}'
          : '';
      final fileName = 'kanban_branding_${AppConfig.clientId}$plantSuffix.$ext';
      final ref = FirebaseStorage.instance.ref().child('kanban_branding/$fileName');
      final snapshot = await ref
          .putData(_brandingPhotoBytes!, SettableMetadata(contentType: contentType))
          .timeout(const Duration(seconds: 60), onTimeout: () => throw Exception('Upload timed out'));
      return await snapshot.ref.getDownloadURL();
    } on FirebaseException catch (e) {
      setState(() => _brandingPhotoError = 'Firebase error: ${e.message}');
      return null;
    } catch (e) {
      setState(() => _brandingPhotoError = 'Upload error: $e');
      return null;
    } finally {
      setState(() => _isUploadingPhoto = false);
    }
  }

  // ── Build (see _pecc_build.dart) ──────────────────────────────────────────

  @override
  Widget build(BuildContext context) => _buildPage(context);
}
