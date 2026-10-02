import 'dart:async';
import '/web_app_template/solar_settlement/solar_settlement_widget.dart';
import '/web_app_template/solar_settlement/settings/solar_settlement_setting_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/pom_group_command_center_widget.dart';
import 'package:smartmachine365/web_app_template/pom_command_center/mill_command_center_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/pom_group_command_center_setting_widget.dart';

import 'package:smartmachine365/models/user_scope.dart';

import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import '../../web_app_template/emission_factor_management/emission_factor_management_widget.dart';
import '../../web_app_template/carbon_dashboard_config_setting/carbon_dashboard_config_setting_widget.dart';
import '../../web_app_template/air_compressor_dashboard_config_setting/air_compressor_dashboard_config_setting_widget.dart';
import '../../web_app_template/sankey_energy_flow/sankey_energy_flow.dart';
import '/flutter_flow/session_storage.dart';
import 'package:smartmachine365/web_app_template/energy_system_settings/energy_system_settings_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/kanban_dashboard_settings_widget.dart';
import 'package:smartmachine365/web_app_template/master_billing_configuration/master_billing_config_widget.dart';
import 'package:smartmachine365/web_app_template/real_time_data_config/discovery_page.dart';
import 'package:smartmachine365/web_app_template/real_time_data_config/live_insight_page.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/general_factory_setting_widgets.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/plant_setting_widget.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/production_area_setting_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/max_demand_monitoring.dart';
import 'package:smartmachine365/web_app_template/md_prediction/md_prediction_page.dart';
import 'package:smartmachine365/web_app_template/power_factor_monitoring/power_factor_monitoring_widget.dart';
import 'package:smartmachine365/web_app_template/tariff_category_setup/widgets/tariff_category_widget.dart';
import 'package:smartmachine365/web_app_template/energy_sankey_setting/energy_sankey_setting_widget.dart';
import 'package:smartmachine365/web_app_template/integration_config/integration_config_widget.dart';
import 'package:smartmachine365/web_app_template/password_management/password_management_widget.dart';
import 'package:smartmachine365/web_app_template/profile_settings/profile_settings_widget.dart';
import 'package:smartmachine365/web_app_template/work_order_overview/cubits/cubits.dart';
import 'package:smartmachine365/web_app_template/work_order_report/cubits/cubits.dart';

import '../../web_app_template/machine_k_p_i/machine_k_p_i_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '/auth/base_auth_user_provider.dart';
import '/flutter_flow/rbac.dart';
import '/flutter_flow/user_presence.dart';

import '/index.dart';
import '/flutter_flow/nav_pages.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/auth/firebase_auth/auth_util.dart';

export 'package:go_router/go_router.dart';
export 'serialization_util.dart';

import 'main_layout.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'router_tracker.dart';
import '/web_app_template/station_page/station_page_widget.dart';
import '/web_app_template/station_page/station_setting_widget.dart';

const kTransitionInfoKey = '__transition_info__';

class AppStateNotifier extends ChangeNotifier {
  AppStateNotifier._() {
    _restoreSessionFromStorage();
  }

  static AppStateNotifier? _instance;
  static AppStateNotifier get instance => _instance ??= AppStateNotifier._();

  BaseAuthUser? initialUser;
  BaseAuthUser? user;
  bool showSplashImage = true;
  String? _redirectLocation;
  String? userRole;
  String? userCompany;
  String? userName;
  String? userEmail;
  String? uid;
  String? factoryId;
  String? landingPage;

  bool notifyOnAuthChange = true;
  List<String> accessibleModules = [];
  List<String> accessibleSubModules = [];

  /// Which plants and production areas this user may see.
  ///
  /// Sits beside the module lists because it answers the same question from
  /// the other side: modules say which screens open, scope says whose data
  /// appears on them. Unrestricted until a role document says otherwise, so
  /// accounts that predate the feature keep working.
  UserScope dataScope = UserScope.unrestricted;

  StreamSubscription? _disabledSub;
  StreamSubscription? _rolesSub;
  bool _forceLoggedOut = false;

  /// Called by MyApp to apply a restored per-user theme.
  /// Set this before the first `update()` call so the theme is applied
  /// as soon as the user's session is restored or a new login completes.
  void Function(ThemeMode mode)? onThemeRestore;

  /// Restore user session data from localStorage on startup.
  /// This allows new tabs to have user data immediately without waiting
  /// for the async API/Firestore calls to resolve.
  void _restoreSessionFromStorage() {
    final session = SessionStorage.getSession();
    if (session != null && session['loggedIn'] == true) {
      uid = session['uid'] as String?;
      userEmail = session['email'] as String?;
      userName = session['userName'] as String?;
      userRole = session['userRole'] as String?;
      userCompany = session['userCompany'] as String?;
      accessibleModules = (session['accessibleModules'] as List<dynamic>?)?.cast<String>() ?? [];
      accessibleSubModules = (session['accessibleSubModules'] as List<dynamic>?)?.cast<String>() ?? [];
      if (accessibleModules.isNotEmpty) {
        AppRoles.setDynamicModules(accessibleModules, accessibleSubModules);
      }
      landingPage = SessionStorage.getSetting<String>('landing_page');
      // Restore per-user theme preference to SharedPreferences so the
      // MaterialApp picks it up on rebuild.
      _restoreUserTheme();
    }
  }

  /// Apply the active user's saved theme preference (dark by default).
  void _restoreUserTheme() {
    final savedTheme = SessionStorage.getSetting<String>('theme_mode');
    final mode = savedTheme == 'light' ? ThemeMode.light : ThemeMode.dark;
    FlutterFlowTheme.saveThemeMode(mode);
    onThemeRestore?.call(mode);
  }

  bool get loading => user == null || showSplashImage;

  /// User is considered logged in for THIS TAB if a session exists in
  /// the per-tab sessionStorage. Firebase Auth state is shared across tabs
  /// (via IndexedDB), so we deliberately do NOT key off `user?.loggedIn` —
  /// otherwise tab B sitting on the login page would get pulled into the
  /// dashboard the moment tab A signs in (and vice versa for sign-out).
  /// `_forceLoggedOut` still wins so admin-disable can kick a tab out.
  bool get loggedIn => !_forceLoggedOut && SessionStorage.hasSession();
  bool get initiallyLoggedIn => initialUser?.loggedIn ?? false;
  bool get shouldRedirect => loggedIn && _redirectLocation != null;
  String? get userUid => user?.uid;
  String getRedirectLocation() => _redirectLocation!;
  bool hasRedirect() => _redirectLocation != null;
  void setRedirectLocationIfUnset(String loc) => _redirectLocation ??= loc;
  void clearRedirectLocation() => _redirectLocation = null;

  void updateNotifyOnAuthChange(bool notify) => notifyOnAuthChange = notify;

  // ── One-time default settings sync ─────────────────────────────────────
  /// Checks if this account has already been synced. If not, copies all
  /// default settings (energy, tariff categories, billing configs, kanban,
  /// facilities) from the first admin/superadmin that has data.
  /// Runs in background — non-blocking, non-fatal.
  Future<void> _maybeSyncDefaults(String userUid) async {
    try {
      // Check the one-time flag.
      final rolesDoc = await FirebaseFirestore.instance.collection('roles').doc(userUid).get();
      if (rolesDoc.exists && rolesDoc.data()?['_defaultsSynced'] == true) {
        return; // Already synced.
      }

      // Find an admin/superadmin with tariff categories.
      const base = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
      final usersRes =
          await http.get(Uri.parse('$base/users/role/all'), headers: {'Content-Type': 'application/json'}).timeout(const Duration(seconds: 15));
      if (usersRes.statusCode != 200) return;

      final List<dynamic> allUsers = json.decode(usersRes.body);
      allUsers.sort((a, b) {
        const p = {'Super Admin': 0, 'Admin': 1};
        return (p[a['roles']] ?? 9).compareTo(p[b['roles']] ?? 9);
      });

      String? sourceUid;
      for (final u in allUsers) {
        final cUid = (u as Map<String, dynamic>)['UID']?.toString() ?? '';
        if (cUid.isEmpty || cUid == userUid) continue;
        final catRes = await http.get(Uri.parse('$base/tariff-categories/list/active?userId=$cUid')).timeout(const Duration(seconds: 10));
        if (catRes.statusCode == 200) {
          final body = json.decode(catRes.body);
          final data = body is Map ? (body['data'] as List<dynamic>? ?? []) : [];
          if (data.isNotEmpty) {
            sourceUid = cUid;
            break;
          }
        }
      }
      if (sourceUid == null) return;

      // ── Helper: simple GET→POST copy ──────────────────────────────────
      Future<void> copyJson(String getUrl, String postUrl) async {
        try {
          final r = await http.get(Uri.parse(getUrl));
          if (r.statusCode != 200 || r.body.isEmpty) return;
          final body = json.decode(r.body);
          if (body == null) return;
          await http.post(Uri.parse(postUrl),
              headers: {'Content-Type': 'application/json'}, body: json.encode(body is Map ? (body['settings'] ?? body) : body));
        } catch (_) {}
      }

      // 1) Energy settings
      await copyJson(
        '$base/energy-settings/$sourceUid',
        '$base/energy-settings/$userUid',
      );

      // Tariff categories and billing configs are shared across every user
      // of this client now (see AppConfig.sharedConfigOwnerId) — no longer
      // copied per-account.

      // 4) Kanban settings
      await copyJson(
        '$base/kanban-settings/$sourceUid',
        '$base/kanban-settings/$userUid',
      );

      // 5) Facilities
      try {
        final facRes = await http.get(Uri.parse('$base/facilities/$sourceUid')).timeout(const Duration(seconds: 15));
        // Only copy if user has no facilities
        final userFacRes = await http.get(Uri.parse('$base/facilities/$userUid')).timeout(const Duration(seconds: 15));
        final userHasFac = userFacRes.statusCode == 200 &&
            userFacRes.body.isNotEmpty &&
            (json.decode(userFacRes.body) is List && (json.decode(userFacRes.body) as List).isNotEmpty);

        if (!userHasFac && facRes.statusCode == 200 && facRes.body.isNotEmpty) {
          final items = json.decode(facRes.body);
          if (items is List) {
            for (final item in items) {
              if (item is! Map) continue;
              await http
                  .post(
                    Uri.parse('$base/facilities/$userUid'),
                    headers: {'Content-Type': 'application/json'},
                    body: json.encode(item),
                  )
                  .timeout(const Duration(seconds: 10));
            }
          }
        }
      } catch (_) {}

      // Mark as synced so this never runs again for this user.
      await FirebaseFirestore.instance.collection('roles').doc(userUid).set(
        {'_defaultsSynced': true},
        SetOptions(merge: true),
      );
    } catch (e) {
      print('Default settings sync failed (non-fatal): $e');
    }
  }

  Future<void> update(BaseAuthUser newUser) async {
    _forceLoggedOut = false;
    final shouldUpdate = user?.uid == null || newUser.uid == null || user?.uid != newUser.uid;
    // The first auth event after page load is definitive for this browser:
    // if Firebase says nobody is signed in, a session cached in localStorage
    // is stale (e.g. left over from a build pointed at another Firebase
    // project) and must not keep the app "logged in" — every Firestore call
    // would then go out unauthenticated and be rejected by the rules.
    final isFirstEvent = initialUser == null;
    initialUser ??= newUser;
    user = newUser;

    // Clear stale data whenever the user changes (logout or account switch)
    // But if the same user is resuming from session (new tab), keep the
    // pre-loaded session data instead of wiping it.
    //
    // Cross-tab guard: Firebase Auth syncs across tabs via IndexedDB, so a
    // signOut() in one tab fires this listener with `newUser.uid == null`
    // in EVERY open tab. If localStorage still holds a valid session
    // (i.e. an explicit logout hasn't run, which would have cleared it
    // first) we treat the null event as a transient cross-tab artifact
    // and refuse to wipe state — otherwise tab A on the dashboard would
    // get logged out the moment tab B clicks "Sign In" on the login page.
    if (shouldUpdate) {
      final isResuming = newUser.uid != null && newUser.uid == uid;
      final isCrossTabPhantomSignOut = newUser.uid == null && SessionStorage.hasSession() && !isFirstEvent;
      if (!isResuming && !isCrossTabPhantomSignOut) {
        SessionStorage.clearSession();
        userRole = null;
        userName = null;
        userEmail = null;
        uid = null;
        factoryId = null;
        accessibleModules = [];
        dataScope = UserScope.unrestricted;
        accessibleSubModules = [];
        AppRoles.clearDynamicModules();
        FlutterFlowTheme.saveThemeMode(ThemeMode.dark);
        onThemeRestore?.call(ThemeMode.dark);
      }
      _disabledSub?.cancel();
      _disabledSub = null;
      _rolesSub?.cancel();
      _rolesSub = null;
    }

    if (user?.uid != null) {
      uid = user?.uid;

      // Load custom roles from Firestore (available for role dropdowns)
      try {
        final crSnap = await FirebaseFirestore.instance.collection('custom_roles').get();
        final customRoles = crSnap.docs.map((doc) {
          final data = Map<String, dynamic>.from(doc.data());
          data['id'] = doc.id;
          return data;
        }).toList();
        AppRoles.setCustomRoles(customRoles);
      } catch (_) {}

      // Get role + name/email from Express.js API
      try {
        final allRes = await http.get(Uri.parse("https://us-central1-smartmill365-demo.cloudfunctions.net/api/users"));
        if (allRes.statusCode == 200) {
          final List<dynamic> allUsers = json.decode(allRes.body);

          // Find by UID first
          Map<String, dynamic>? match = allUsers.firstWhere(
            (u) => u['UID']?.toString() == uid,
            orElse: () => null,
          );

          // Fallback by email if UID not found
          if (match == null) {
            final email = user?.email;
            if (email != null) {
              match = allUsers.firstWhere(
                (u) => u['email']?.toString().toLowerCase() == email.toLowerCase(),
                orElse: () => null,
              );
              // Auto-fix UID mismatch
              if (match != null) {
                await http.put(
                  Uri.parse("https://us-central1-smartmill365-demo.cloudfunctions.net/api/users/fixUid/${match['id']}"),
                  headers: {'Content-Type': 'application/json'},
                  body: json.encode({'uid': uid}),
                );
              }
            }
          }

          if (match != null) {
            userRole = match['roles'] as String?;
            userName = match['name'] as String?;
            userEmail = match['email'] as String?;
            factoryId = match['factory_id']?.toString();
          }
        }
      } catch (e) {
        print('User fetch failed: $e');
      }

      // ── Load from Firestore roles/{uid} — authoritative source for role edits ─
      if (uid != null) {
        try {
          final rolesDoc = await FirebaseFirestore.instance.collection('roles').doc(uid).get();
          if (rolesDoc.exists) {
            final data = rolesDoc.data()!;
            // roles/{uid}.name overrides API role (edits are saved here)
            final firestoreRole = data['name'] as String?;
            if (firestoreRole != null && firestoreRole.isNotEmpty) {
              userRole = firestoreRole;
            }
            // Also pick up display_name / email if stored
            final displayName = data['display_name'] as String?;
            if (displayName != null && displayName.isNotEmpty) {
              userName = displayName;
            }

            // Load per-user module permissions. Trust the stored arrays
            // exactly as the admin saved them — including an empty list,
            // which legitimately means "no access until reassigned".
            final hasModulesField = data.containsKey('accessible_modules');
            if (hasModulesField) {
              final storedModules = (data['accessible_modules'] as List<dynamic>?)?.cast<String>() ?? [];
              final storedSub = (data['accessible_sub_modules'] as List<dynamic>?)?.cast<String>() ?? [];
              accessibleModules = storedModules;
              accessibleSubModules = storedSub;
              AppRoles.setDynamicModules(accessibleModules, accessibleSubModules);
            }

            // Data scope. A missing field means unrestricted — see UserScope —
            // so an account saved before this existed keeps full access.
            dataScope = UserScope.fromJson(
                data['data_scope'] as Map<String, dynamic>?);

            // Load landing_page so _HomeRedirectWidget navigates correctly.
            final firestoreLandingPage = data['landing_page'] as String?;
            if (firestoreLandingPage != null && firestoreLandingPage.isNotEmpty) {
              landingPage = firestoreLandingPage;
              SessionStorage.saveSetting('landing_page', firestoreLandingPage);
            }
          }
        } catch (_) {}

        // No role-default fallback. If the user has no roles/{uid} doc yet,
        // they get no module access until an admin assigns modules.
      }

      // Fallback: always populate email/name from Firebase Auth if still null
      userEmail ??= user?.email;
      userName ??= user?.displayName ?? user?.email;

      // Fallback 1: query Firestore customers collection directly by UID or email
      if ((userRole == null || userRole!.isEmpty) && uid != null) {
        try {
          var snap = await FirebaseFirestore.instance.collection('customers').where('UID', isEqualTo: uid).limit(1).get();
          if (snap.docs.isEmpty && user?.email != null) {
            snap = await FirebaseFirestore.instance.collection('customers').where('email', isEqualTo: user!.email).limit(1).get();
          }
          if (snap.docs.isNotEmpty) {
            final data = snap.docs.first.data();
            userRole = data['roles'] as String?;
            userName ??= data['name'] as String?;
            userEmail ??= data['email'] as String?;
            factoryId ??= data['factory_id']?.toString();
            // Don't inject role defaults here — the customers collection is
            // only used to recover the role string. Module access still
            // requires an explicit roles/{uid} assignment by an admin.
          }
        } catch (e) {
          print('Firestore customers fallback failed: $e');
        }
      }

      // ── Migration: ensure granular module keys exist ────────────────────
      // If the stored accessible_modules don't contain any granular keys,
      // the user was created before per-module permissions — upgrade them.
      if (userRole != null && uid != null && accessibleModules.isNotEmpty) {
        final hasGranular = accessibleModules.any((m) => AppRoles.allModuleKeys.contains(m));
        if (!hasGranular) {
          final granular = AppRoles.defaultGranularModules(userRole!);
          accessibleModules = {...accessibleModules, ...granular}.toList();
          AppRoles.setDynamicModules(accessibleModules, accessibleSubModules);
          // Persist the migration so it only runs once
          FirebaseFirestore.instance.collection('roles').doc(uid).set({
            'accessible_modules': accessibleModules,
          }, SetOptions(merge: true)).catchError((_) {});
        }
      }
    }

    // ── One-time default settings sync for old accounts ─────────────────
    // If this user has never been synced (no _defaultsSynced flag in their
    // roles doc), copy default settings from a superadmin/admin.  Runs in
    // the background so it doesn't block login.
    if (uid != null && userRole != null) {
      final normalizedRole = AppRoles.normalizeRole(userRole!);
      // Only sync for non-superadmin accounts (superadmin IS the source).
      if (normalizedRole != AppRoles.superAdmin) {
        _maybeSyncDefaults(uid!);
      }
    }

    // Save user session to localStorage for management access
    if (uid != null) {
      SessionStorage.saveSession(
        uid: uid,
        email: userEmail,
        userName: userName,
        userRole: userRole,
        accessToken: currentJwtToken,
        userCompany: userCompany,
        accessibleModules: accessibleModules,
        accessibleSubModules: accessibleSubModules,
      );
      // Restore per-user theme after login so each user sees their preference
      _restoreUserTheme();
      // Load saved landing page so GoRouter redirect fires with correct value
      landingPage ??= SessionStorage.getSetting<String>('landing_page');
    }

    // Update presence — always re-register when we have a valid session
    // Presence is independent of role resolution; only needs a valid UID.
    // Skipped while a login attempt is in flight: the login flow manages
    // its own goOnline call with a fresh session_id.
    if (uid != null && !UserPresence.suspendAutoStart) {
      UserPresence.goOnline(uid!);
    }

    // Watch account_status/{uid} — force sign-out if admin disables account
    if (uid != null && _disabledSub == null) {
      final listenUid = uid!;
      _disabledSub = FirebaseFirestore.instance.collection('account_status').doc(listenUid).snapshots().listen((snap) {
        if (snap.exists && snap.data()?['disabled'] == true) {
          _disabledSub?.cancel();
          _disabledSub = null;
          _rolesSub?.cancel();
          _rolesSub = null;
          UserPresence.goOffline(listenUid).catchError((_) {});
          AppRoles.clearDynamicModules();
          SessionStorage.clearSession();
          userRole = null;
          userName = null;
          userEmail = null;
          uid = null;
          accessibleModules = [];
          dataScope = UserScope.unrestricted;
          accessibleSubModules = [];
          FlutterFlowTheme.saveThemeMode(ThemeMode.dark);
          onThemeRestore?.call(ThemeMode.dark);
          // Force loggedIn to return false IMMEDIATELY so router redirects to login
          _forceLoggedOut = true;
          notifyListeners();
          // Then actually sign out Firebase Auth
          fb_auth.FirebaseAuth.instance.signOut().catchError((_) {});
        }
      });
    }

    // Watch roles/{uid} — live-update nav when admin changes permissions/role
    if (uid != null && _rolesSub == null) {
      final listenUid = uid!;
      _rolesSub = FirebaseFirestore.instance.collection('roles').doc(listenUid).snapshots().listen((snap) {
        if (!snap.exists) return;
        final data = snap.data()!;
        final newRole = data['name'] as String?;
        final newModules = (data['accessible_modules'] as List<dynamic>?)?.cast<String>() ?? [];
        final newSub = (data['accessible_sub_modules'] as List<dynamic>?)?.cast<String>() ?? [];

        bool changed = false;

        if (newRole != null && newRole.isNotEmpty && newRole != userRole) {
          userRole = newRole;
          changed = true;
        }
        // Always process modules — even empty list means "no permissions"
        final newSet = newModules.toSet();
        final oldSet = accessibleModules.toSet();
        if (newSet.length != oldSet.length || !newSet.containsAll(oldSet)) {
          accessibleModules = newModules;
          accessibleSubModules = newSub;
          AppRoles.setDynamicModules(accessibleModules, accessibleSubModules);
          changed = true;
        }

        // Also pick up name changes
        final displayName = data['display_name'] as String?;
        if (displayName != null && displayName.isNotEmpty && displayName != userName) {
          userName = displayName;
          changed = true;
        }

        // Load landing page preference
        final savedLandingPage = data['landing_page'] as String?;
        if (savedLandingPage != null && savedLandingPage != landingPage) {
          landingPage = savedLandingPage;
          SessionStorage.saveSetting('landing_page', savedLandingPage);
        }

        if (changed) {
          // Update localStorage session with latest data
          SessionStorage.saveSession(
            uid: uid,
            email: userEmail,
            userName: userName,
            userRole: userRole,
            accessToken: currentJwtToken,
            userCompany: userCompany,
            accessibleModules: accessibleModules,
            accessibleSubModules: accessibleSubModules,
          );
          notifyListeners(); // forces sidebar + routes to re-render
        }
      });
    }

    // Always notify after role/modules are resolved so the sidebar
    // re-renders with the correct permissions (fixes race condition
    // where the first paint had stale or missing data).
    if (notifyOnAuthChange) {
      notifyListeners();
    }
    updateNotifyOnAuthChange(true);
  }

  void stopShowingSplashImage() {
    showSplashImage = false;
    notifyListeners();
  }
}

/// Redirects a logged-in user to their preferred landing page.
/// Shows EquipmentOverview as a placeholder while the post-frame redirect fires.
class _HomeRedirectWidget extends StatefulWidget {
  final AppStateNotifier appState;
  const _HomeRedirectWidget({required this.appState});
  @override
  State<_HomeRedirectWidget> createState() => _HomeRedirectWidgetState();
}

class _HomeRedirectWidgetState extends State<_HomeRedirectWidget> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = widget.appState;
      final home = resolveHomePage(
        s.landingPage,
        s.accessibleModules,
        s.userRole ?? '',
      );
      context.goNamed(home);
    });
  }

  @override
  Widget build(BuildContext context) =>
      const MainLayout(child: EquipmentOverviewWidget());
}

GoRouter createRouter(AppStateNotifier appStateNotifier) => GoRouter(
      initialLocation: '/',
      debugLogDiagnostics: false,
      refreshListenable: appStateNotifier,
      errorBuilder: (context, state) => appStateNotifier.loggedIn ? const MainLayout(child: EquipmentOverviewWidget()) : const LoginPageWidget(),
      routes: [
        FFRoute(
            name: '_initialize',
            path: '/',
            builder: (context, _) => appStateNotifier.loggedIn
                ? _HomeRedirectWidget(appState: appStateNotifier)
                : const LoginPageWidget()),
        FFRoute(
          name: 'EquipmentOverview',
          path: '/equipmentOverview',
          // Dashboard — all roles
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EquipmentOverviewWidget()),
        ),
        // Equipment Monitoring station pages: one card per equipment whose
        // category is the station's (set up in Equipment Settings).
        FFRoute(
          name: 'SterilizerStation',
          path: '/sterilizerStation',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(
              child: StationPageWidget(key: ValueKey('station-sterilizer'), stationKey: 'sterilizer')),
        ),
        FFRoute(
          name: 'DigesterStation',
          path: '/digesterStation',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(
              child: StationPageWidget(key: ValueKey('station-digester'), stationKey: 'digester')),
        ),
        FFRoute(
          name: 'StationPageSetting',
          path: '/stationPageSetting',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) {
            final station = params.getParam('station', ParamType.String) as String?;
            return MainLayout(
                child: StationSettingWidget(key: ValueKey('station-setting-${station ?? ''}'), initialStation: station));
          },
        ),
        FFRoute(
            name: 'AlarmSettings',
            path: '/alarmSettings',
            rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
            builder: (context, params) {
              final appStateNotifier = AppStateNotifier.instance;
              final userCompany = appStateNotifier.userCompany ?? ' ';
              final userRole = appStateNotifier.userRole ?? ' ';
              return MainLayout(
                child: AlarmSettingsWidget(companyID: userCompany, userRole: userRole),
              );
            }),
        FFRoute(
          name: 'DeviceSettings',
          path: '/deviceSettings',
          rolesAllowed: ['Super Admin'],
          builder: (context, params) => const MainLayout(child: DeviceSettingsWidget()),
        ),
        FFRoute(
          name: 'DeviceDiscovery',
          path: '/deviceDiscovery',
          rolesAllowed: ['Super Admin', 'Admin'],
          builder: (context, params) => const MainLayout(child: RealTimeDiscoveryPage()),
        ),
        FFRoute(
          name: 'DeviceLiveInsight',
          path: '/deviceLiveInsight',
          rolesAllowed: ['Super Admin', 'Admin'],
          builder: (context, params) => const MainLayout(child: DeviceLiveInsightPage()),
        ),
        FFRoute(
            name: 'EquipmentSettings',
            path: '/equipmentSettings',
            rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
            builder: (context, params) {
              final appStateNotifier = AppStateNotifier.instance;
              final userRole = appStateNotifier.userRole ?? ' ';
              final fid = appStateNotifier.factoryId ?? '';
              return MainLayout(
                child: EquipmentSettingsWidget(userRole: userRole, factoryId: fid),
              );
            }),
        FFRoute(
            name: 'ManageUserGroups',
            path: '/manageUserGroups',
            rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
            builder: (context, params) {
              final appStateNotifier = AppStateNotifier.instance;
              final userRole = appStateNotifier.userRole ?? '';
              final userName = appStateNotifier.userName ?? '';
              final userUid = appStateNotifier.uid ?? '';
              final userEmail = appStateNotifier.userEmail ?? '';
              return MainLayout(
                child: ManageUserGroupsWidget(
                  userUid: userUid,
                  userRole: userRole,
                  userName: userName,
                  userEmail: userEmail,
                ),
              );
            }),
        FFRoute(
          name: 'loginPage',
          path: '/loginPage',
          builder: (context, params) => const LoginPageWidget(),
        ),
        FFRoute(
          name: 'EquipmentDetails',
          path: '/equipmentDetails',
          // Dashboards — all roles
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) {
            try {
              final equipmentId = params.getParam('equipmentId', ParamType.String);
              final productionAreaName = params.getParam('productionAreaName', ParamType.String);

              return MainLayout(
                child: EquipmentDetailsWidget(
                  selectedEquipmentId: equipmentId,
                  productionAreaName: productionAreaName,
                ),
              );
            } catch (e) {
              // Handle missing parameters by redirecting or showing a different UI
              return MainLayout(
                child: EquipmentDetailsWidget(
                  selectedEquipmentId: "",
                  productionAreaName: "",
                ),
              );
            }
          },
        ),
        FFRoute(
          name: 'EnergyOverview',
          path: '/energyOverview',
          // Dashboards — all roles
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EnergyOverviewWidget()),
        ),
        FFRoute(
          name: 'EnergyDetails',
          path: '/energyDetails',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EnergyDetailsWidget()),
        ),
        FFRoute(
            name: 'WorkOrderOverview',
            path: '/WorkOrderOverview',
            // Manager+ can access
            rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer'],
            builder: (context, params) {
              final appStateNotifier = AppStateNotifier.instance;
              final userCompany = appStateNotifier.userCompany ?? ' ';
              final userRole = appStateNotifier.userRole ?? ' ';
              return MainLayout(
                child: RepositoryProvider(
                  create: (_) => WorkOrderRepository(),
                  child: WorkOrderOverviewWidget(companyID: userCompany, userRole: userRole),
                ),
              ); // ✅
            }),
        FFRoute(
          name: 'WorkOrderDetails',
          path: '/workOrderDetails',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) {
            try {
              final equipmentId = params.getParam('equipmentId', ParamType.String);
              final productionAreaName = params.getParam('productionAreaName', ParamType.String);

              return MainLayout(
                child: EquipmentDetailsWidget(selectedEquipmentId: equipmentId, productionAreaName: productionAreaName, isWorkOrderDetails: true),
              );
            } catch (e) {
              // Handle missing parameters by redirecting or showing a different UI
              return MainLayout(
                child: EquipmentDetailsWidget(selectedEquipmentId: "", productionAreaName: "", isWorkOrderDetails: true),
              );
            }
          },
        ),
        FFRoute(
          name: 'CarbonEmission',
          path: '/carbonEmission',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: CarbonEmissionWidget()),
        ),
        FFRoute(
          name: 'PowerFactorMonitoring',
          path: '/powerFactorMonitoring',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: PowerFactorMonitoringWidget()),
        ),
        FFRoute(
          name: 'AirCompressorMonitoring',
          path: '/airCompressorMonitoring',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: AirCompressorMonitoringWidget()),
        ),
        FFRoute(
          name: 'Reports',
          path: '/reports',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: ReportsWidget()),
        ),
        FFRoute(
          name: 'MdInsightReport',
          path: '/mdInsightReport',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: MdInsightReportWidget()),
        ),
        FFRoute(
          name: 'EnergyComparison',
          path: '/EnergyComparison',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => MainLayout(
            child: EnergyComparisonWidget(
              pageTitle: 'Energy Historical Data',
              breadcrumbTitle: 'Dashboard/Energy Historical Data',
              initialDeviceId: params.getParam<String>('deviceId', ParamType.String),
            ),
          ),
        ),
        FFRoute(
          name: 'DeviceEnergyComparison',
          path: '/DeviceEnergyComparison',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => MainLayout(
            child: DeviceEnergyComparisonWidget(
              initialDeviceId: params.getParam<String>('deviceId', ParamType.String),
            ),
          ),
        ),
        FFRoute(
          name: 'ProductionLineKPI',
          path: '/productionLineKPI',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: ProductionLineKPIWidget()),
        ),
        FFRoute(
          name: 'MachineKPI',
          path: '/machineKPI',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: MachineKPIWidget()),
        ),
        FFRoute(
          name: 'MaxDemandMonitoring',
          path: '/maxDemandMonitoring',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: MaxDemandMonitoring()),
        ),
        FFRoute(
          name: 'MdPrediction',
          path: '/mdPrediction',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: MdPredictionPage()),
        ),
        FFRoute(
          name: 'SankeyEnergyFlow',
          path: '/sankeyEnergyFlow',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: SankeyEnergyFlow()),
        ),
        FFRoute(
          name: 'kwhTone',
          path: '/kwhTone',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: KwhPerTonneWidget()),
        ),
        FFRoute(
          name: 'SecComparisonInsight',
          path: '/secComparisonInsight',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: SecComparisonInsightWidget()),
        ),
        FFRoute(
          name: 'ProductionOutputLog',
          path: '/productionOutputLog',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: ProductionOutputLogWidget()),
        ),
        FFRoute(
          name: 'Factory25Dashboard',
          path: '/factory25Dashboard',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: Factory25DashboardWidget()),
        ),
        FFRoute(
          name: 'WorkOrderReport',
          path: '/WorkOrderReport',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => MainLayout(
            child: RepositoryProvider(
              create: (_) => WorkOrderReportRepository(),
              child: const WorkOrderReportWidget(),
            ),
          ),
        ),
        FFRoute(
          name: 'ProductSettings',
          path: '/ProductSettings',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: ProductSettingsWidget()),
        ),
        FFRoute(
          name: 'EnergySystemSettings',
          path: '/EnergySystemSettings',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: EnergySystemSettingsWidget()),
        ),
        FFRoute(
          name: 'KanbanDashboardSettings',
          path: '/KanbanDashboardSettings',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: KanbanDashboardSettingsWidget()),
        ),
        FFRoute(
          name: 'PlantEnergyCommandCenterSetting',
          path: '/PlantEnergyCommandCenterSetting',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          // SmartMill has no energy command centres: this route (and any
          // link still pointing at it) now opens the POM settings.
          builder: (context, params) => const MainLayout(child: PomGroupCommandCenterSettingWidget()),
        ),
        FFRoute(
          name: 'MasterBillingConfig',
          path: '/MasterBillingConfig',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: MasterBillingConfigWidget()),
        ),
        FFRoute(
          name: 'MasterFacilitySetting',
          path: '/MasterFacilitySetting',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: MasterFacilitySettingWidget()),
        ),
        FFRoute(
          name: 'GfsPlant',
          path: '/GfsPlant',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) {
            final role = AppStateNotifier.instance.userRole ?? '';
            final fid = AppStateNotifier.instance.factoryId ?? '';
            return MainLayout(child: PlantSettingWidget(userRole: role, factoryId: fid));
          },
        ),
        FFRoute(
          name: 'GfsProductionArea',
          path: '/GfsProductionArea',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) {
            final fid = AppStateNotifier.instance.factoryId ?? '';
            return MainLayout(child: ProductionAreaSettingWidget(factoryId: fid, userRole: AppStateNotifier.instance.userRole ?? ''));
          },
        ),
        FFRoute(
          name: 'GfsProductionLine',
          path: '/GfsProductionLine',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: GfsProductionLineWidget()),
        ),
        FFRoute(
          name: 'GfsEquipment',
          path: '/GfsEquipment',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) {
            final appStateNotifier = AppStateNotifier.instance;
            final userRole = appStateNotifier.userRole ?? ' ';
            final fid = appStateNotifier.factoryId ?? '';
            return MainLayout(child: EquipmentSettingsWidget(userRole: userRole, factoryId: fid));
          },
        ),
        FFRoute(
          name: 'GfsProcess',
          path: '/GfsProcess',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: GfsProcessWidget()),
        ),
        FFRoute(
          name: 'GfsProduct',
          path: '/GfsProduct',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: ProductSettingsWidget()),
        ),
        FFRoute(
          name: 'GfsAbnormalReason',
          path: '/GfsAbnormalReason',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: GfsAbnormalReasonWidget()),
        ),
        // TODO: GfsProductProcessRouting — not implemented yet
        // FFRoute(
        //   name: 'GfsProductProcessRouting',
        //   path: '/GfsProductProcessRouting',
        //   rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
        //   builder: (context, params) => const MainLayout(child: GfsProductProcessRoutingWidget()),
        // ),
        // TODO: GfsInstrumentDevices — not implemented yet
        // FFRoute(
        //   name: 'GfsInstrumentDevices',
        //   path: '/GfsInstrumentDevices',
        //   rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
        //   builder: (context, params) => const MainLayout(child: GfsInstrumentDevicesWidget()),
        // ),
        // TODO: GfsParameterSetting — not implemented yet
        // FFRoute(
        //   name: 'GfsParameterSetting',
        //   path: '/GfsParameterSetting',
        //   rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
        //   builder: (context, params) => const MainLayout(child: GfsParameterSettingWidget()),
        // ),
        FFRoute(
          name: 'GfsAlarm',
          path: '/GfsAlarm',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) {
            final appStateNotifier = AppStateNotifier.instance;
            final userCompany = appStateNotifier.userCompany ?? ' ';
            final userRole = appStateNotifier.userRole ?? ' ';
            return MainLayout(child: AlarmSettingsWidget(companyID: userCompany, userRole: userRole));
          },
        ),
        FFRoute(
          name: 'GfsShift',
          path: '/GfsShift',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: GfsShiftWidget()),
        ),
        FFRoute(
          name: 'GfsEquipmentCategory',
          path: '/GfsEquipmentCategory',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: EquipmentCategorySettingWidget()),
        ),
        FFRoute(
          name: 'GfsDeviceType',
          path: '/GfsDeviceType',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: GfsDeviceTypeWidget()),
        ),
        FFRoute(
          name: 'GfsTnbMeter',
          path: '/GfsTnbMeter',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: GfsTnbMeterWidget()),
        ),
        // TODO: GfsShiftCalendar — not implemented yet
        // FFRoute(
        //   name: 'GfsShiftCalendar',
        //   path: '/GfsShiftCalendar',
        //   rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
        //   builder: (context, params) => const MainLayout(child: GfsShiftCalendarWidget()),
        // ),
        // TODO: GfsDowntimeCalendar — not implemented yet
        // FFRoute(
        //   name: 'GfsDowntimeCalendar',
        //   path: '/GfsDowntimeCalendar',
        //   rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
        //   builder: (context, params) => const MainLayout(child: GfsDowntimeCalendarWidget()),
        // ),
        FFRoute(
          name: 'TariffCategorySetup',
          path: '/TariffCategorySetup',
          // Tariffs — Manager + Engineer can VIEW
          rolesAllowed: ['Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: TariffCategoryWidget()),
        ),
        FFRoute(
          name: 'EnergySankeyFlowSetting',
          path: '/EnergySankeyFlowSetting',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: EnergySankeySettingWidget()),
        ),
        FFRoute(
          name: 'IntegrationConfig',
          path: '/IntegrationConfig',
          rolesAllowed: ['Super Admin'],
          builder: (context, params) => const MainLayout(child: IntegrationConfigWidget()),
        ),
        FFRoute(
          name: 'PasswordManagement',
          path: '/PasswordManagement',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: PasswordManagementWidget()),
        ),
        FFRoute(
          name: 'ProfileSettings',
          path: '/ProfileSettings',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: ProfileSettingsWidget()),
        ),
        FFRoute(
          name: 'EmissionFactorManagement',
          path: '/emissionFactorManagement',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: EmissionFactorManagementWidget()),
        ),
        FFRoute(
          name: 'CarbonDashboardConfigSetting',
          path: '/carbonDashboardConfigSetting',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: CarbonDashboardConfigSettingWidget()),
        ),
        FFRoute(
          name: 'AirCompressorDashboardConfigSetting',
          path: '/airCompressorDashboardConfigSetting',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager'],
          builder: (context, params) => const MainLayout(child: AirCompressorDashboardConfigSettingWidget()),
        ),
        FFRoute(
          name: 'KanbanDashboard',
          path: '/KanbanDashboard',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          // SmartMill has no energy command centres: this route (and any
          // link still pointing at it) now opens the Group POM Command Center.
          builder: (context, params) => const MainLayout(child: PomGroupCommandCenterWidget()),
        ),
        FFRoute(
          name: 'PomGroupCommandCenter',
          path: '/PomGroupCommandCenter',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: PomGroupCommandCenterWidget()),
        ),
        FFRoute(
          name: 'PomGroupCommandCenterSetting',
          path: '/PomGroupCommandCenterSetting',
          rolesAllowed: ['Super Admin', 'Admin'],
          builder: (context, params) => const MainLayout(child: PomGroupCommandCenterSettingWidget()),
        ),
        FFRoute(
          name: 'MillCommandCenter',
          path: '/millCommandCenter',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          // Dynamic, not per-mill: any mill added in the Group setting is
          // reachable here immediately by its id, with nothing to wire up.
          builder: (context, params) => MainLayout(
            child: MillCommandCenterWidget(millId: params.getParam<String>('mill', ParamType.String) ?? ''),
          ),
        ),
        FFRoute(
          name: 'TnbE3BillSimulator',
          path: '/tnbE3BillSimulator',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: TnbE3BillSimulatorWidget()),
        ),
        FFRoute(
          name: 'TnbBillDataLogger',
          path: '/tnbBillDataLogger',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: TnbBillDataLoggerWidget()),
        ),
        FFRoute(
          name: 'SolarSettlement',
          path: '/solarSettlement',
          rolesAllowed: ['Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: SolarSettlementWidget()),
        ),
        FFRoute(
          name: 'SolarSettlementSetting',
          path: '/solarSettlementSetting',
          // Route guards are off app-wide; the page itself admits Super Admin only.
          rolesAllowed: ['Super Admin'],
          builder: (context, params) => const MainLayout(child: SolarSettlementSettingWidget()),
        ),
        FFRoute(
          name: 'OEEData',
          path: '/OEEData',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: OeeDataWidget()),
        ),
        FFRoute(
          name: 'EnergyDataLogger',
          path: '/EnergyDataLogger',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EnergyDataLoggerWidget()),
        ),
        FFRoute(
          name: 'EnergyDataLogger1',
          path: '/EnergyDataLogger1',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EnergyDataLogger1Widget()),
        ),
        FFRoute(
          name: 'EnergyDataLogger2',
          path: '/EnergyDataLogger2',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EnergyDataLogger2Widget()),
        ),
        FFRoute(
          name: 'EnergyVsWorkOrder',
          path: '/EnergyVsWorkOrder',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EnergyVsWorkOrderWidget()),
        ),
        FFRoute(
          name: 'EquipmentEnergyData',
          path: '/EquipmentEnergyData',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EquipmentEnergyDataWidget()),
        ),
        FFRoute(
          name: 'EquipmentStatusData',
          path: '/EquipmentStatusData',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EquipmentStatusDataWidget()),
        ),
        FFRoute(
          name: 'EquipmentDataLogger',
          path: '/EquipmentDataLogger',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: EquipmentDataLoggerWidget()),
        ),
        FFRoute(
          name: 'EquipmentAlarmData',
          path: '/EquipmentAlarmData',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer', 'Operator'],
          builder: (context, params) => const MainLayout(child: EquipmentAlarmDataWidget()),
        ),
        FFRoute(
          name: 'ProductionCalendar',
          path: '/ProductionCalendar',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: ProductionCalendarWidget()),
        ),
        FFRoute(
          name: 'MCWOQtyDataLogger',
          path: '/MCWOQtyDataLogger',
          rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer'],
          builder: (context, params) => const MainLayout(child: McWoQtyDataLoggerWidget()),
        ),
        FFRoute(
            name: 'ProductionTaskWorkStation',
            path: '/ProductionTaskWorkStation',
            rolesAllowed: ['Viewer', 'Super Admin', 'Admin', 'Manager', 'Engineer'],
            builder: (context, params) {
              final appStateNotifier = AppStateNotifier.instance;
              final userCompany = appStateNotifier.userCompany ?? ' ';
              final userRole = appStateNotifier.userRole ?? ' ';
              return MainLayout(
                child: RepositoryProvider(
                  create: (_) => WorkOrderRepository(),
                  child: ProductionTaskWorkStationWidget(companyID: userCompany, userRole: userRole),
                ),
              ); // ✅
            }),
      ].map((r) => r.toRoute(appStateNotifier)).toList(),
    );

extension NavParamExtensions on Map<String, String?> {
  Map<String, String> get withoutNulls => Map.fromEntries(
        entries.where((e) => e.value != null).map((e) => MapEntry(e.key, e.value!)),
      );
}

extension NavigationExtensions on BuildContext {
  void goNamedAuth(
    String name,
    bool mounted, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, String> queryParameters = const <String, String>{},
    Object? extra,
    bool ignoreRedirect = false,
  }) =>
      !mounted || GoRouter.of(this).shouldRedirect(ignoreRedirect)
          ? null
          : goNamed(
              name,
              pathParameters: pathParameters,
              queryParameters: queryParameters,
              extra: extra,
            );

  void pushNamedAuth(
    String name,
    bool mounted, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, String> queryParameters = const <String, String>{},
    Object? extra,
    bool ignoreRedirect = false,
  }) =>
      !mounted || GoRouter.of(this).shouldRedirect(ignoreRedirect)
          ? null
          : pushNamed(
              name,
              pathParameters: pathParameters,
              queryParameters: queryParameters,
              extra: extra,
            );

  void safePop() {
    if (canPop()) {
      pop();
    } else {
      go('/');
    }
  }
}

extension GoRouterExtensions on GoRouter {
  AppStateNotifier get appState => AppStateNotifier.instance;
  void prepareAuthEvent([bool ignoreRedirect = false]) => appState.hasRedirect() && !ignoreRedirect ? null : appState.updateNotifyOnAuthChange(false);
  bool shouldRedirect(bool ignoreRedirect) => !ignoreRedirect && appState.hasRedirect();
  void clearRedirectLocation() => appState.clearRedirectLocation();
  void setRedirectLocationIfUnset(String location) => appState.updateNotifyOnAuthChange(false);
}

extension _GoRouterStateExtensions on GoRouterState {
  Map<String, dynamic> get extraMap => extra != null ? extra as Map<String, dynamic> : {};
  Map<String, dynamic> get allParams => <String, dynamic>{}
    ..addAll(pathParameters)
    ..addAll(uri.queryParameters)
    ..addAll(extraMap);
  TransitionInfo get transitionInfo =>
      extraMap.containsKey(kTransitionInfoKey) ? extraMap[kTransitionInfoKey] as TransitionInfo : TransitionInfo.appDefault();
}

class FFParameters {
  FFParameters(this.state, [this.asyncParams = const {}]);

  final GoRouterState state;
  final Map<String, Future<dynamic> Function(String)> asyncParams;

  Map<String, dynamic> futureParamValues = {};

  // Parameters are empty if the params map is empty or if the only parameter
  // present is the special extra parameter reserved for the transition info.
  bool get isEmpty => state.allParams.isEmpty || (state.allParams.length == 1 && state.extraMap.containsKey(kTransitionInfoKey));
  bool isAsyncParam(MapEntry<String, dynamic> param) => asyncParams.containsKey(param.key) && param.value is String;
  bool get hasFutures => state.allParams.entries.any(isAsyncParam);
  Future<bool> completeFutures() => Future.wait(
        state.allParams.entries.where(isAsyncParam).map(
          (param) async {
            final doc = await asyncParams[param.key]!(param.value).onError((_, __) => null);
            if (doc != null) {
              futureParamValues[param.key] = doc;
              return true;
            }
            return false;
          },
        ),
      ).onError((_, __) => [false]).then((v) => v.every((e) => e));

  dynamic getParam<T>(
    String paramName,
    ParamType type, {
    bool isList = false,
    List<String>? collectionNamePath,
  }) {
    if (futureParamValues.containsKey(paramName)) {
      return futureParamValues[paramName];
    }
    if (!state.allParams.containsKey(paramName)) {
      return null;
    }
    final param = state.allParams[paramName];
    if (param is! String) {
      return param;
    }
    return deserializeParam<T>(
      param,
      type,
      isList,
      collectionNamePath: collectionNamePath,
    );
  }
}

class FFRoute {
  const FFRoute({
    required this.name,
    required this.path,
    required this.builder,
    this.requireAuth = false,
    this.asyncParams = const {},
    this.routes = const [],
    this.rolesAllowed = const [],
  });

  final String name;
  final String path;
  final bool requireAuth;
  final Map<String, Future<dynamic> Function(String)> asyncParams;
  final Widget Function(BuildContext, FFParameters) builder;
  final List<GoRoute> routes;
  final List<String> rolesAllowed;

  GoRoute toRoute(AppStateNotifier appStateNotifier) => GoRoute(
        name: name,
        path: path,
        redirect: (context, state) {
          // Don't redirect while Firebase Auth is still loading and session exists
          if (appStateNotifier.loading && SessionStorage.hasSession() && name != 'loginPage') {
            return null;
          }
          // Force redirect to login when account is disabled or user signed out
          if (!appStateNotifier.loggedIn && name != 'loginPage') {
            return '/loginPage';
          }
          if (appStateNotifier.shouldRedirect) {
            final redirectLocation = appStateNotifier.getRedirectLocation();
            appStateNotifier.clearRedirectLocation();
            return redirectLocation;
          }
          if (requireAuth && !appStateNotifier.loggedIn) {
            appStateNotifier.setRedirectLocationIfUnset(state.uri.toString());
            return '/loginPage';
          }
          // Route-level role guards are intentionally disabled. Access is
          // now controlled exclusively by per-user module assignments
          // (roles/{uid}.accessible_modules) via AppRoles.canAccess, which
          // the sidebar and per-page widgets already enforce. The hardcoded
          // rolesAllowed list previously blocked admin-assigned access for
          // non-built-in / non-listed roles (e.g. a Operator given the
          // Settings module would still be redirected away here).
          return null;
        },
        pageBuilder: (context, state) {
          fixStatusBarOniOS16AndBelow(context);
          routeTracker.updateRoute(state.uri.toString());
          final ffParams = FFParameters(state, asyncParams);
          final page = ffParams.hasFutures
              ? FutureBuilder(
                  future: ffParams.completeFutures(),
                  builder: (context, _) => builder(context, ffParams),
                )
              : builder(context, ffParams);
          final child = appStateNotifier.loading
              ? Container(
                  color: Colors.transparent,
                  child: Image.asset(
                    'assets/images/Login.png',
                    fit: BoxFit.cover,
                  ),
                )
              : page;

          final transitionInfo = state.transitionInfo;
          return transitionInfo.hasTransition
              ? CustomTransitionPage(
                  key: state.pageKey,
                  child: child,
                  transitionDuration: transitionInfo.duration,
                  transitionsBuilder: (context, animation, secondaryAnimation, child) => PageTransition(
                    type: transitionInfo.transitionType,
                    duration: transitionInfo.duration,
                    reverseDuration: transitionInfo.duration,
                    alignment: transitionInfo.alignment,
                    child: child,
                  ).buildTransitions(
                    context,
                    animation,
                    secondaryAnimation,
                    child,
                  ),
                )
              : MaterialPage(key: state.pageKey, child: child);
        },
        routes: routes,
      );
}

class TransitionInfo {
  const TransitionInfo({
    required this.hasTransition,
    this.transitionType = PageTransitionType.fade,
    this.duration = const Duration(milliseconds: 300),
    this.alignment,
  });

  final bool hasTransition;
  final PageTransitionType transitionType;
  final Duration duration;
  final Alignment? alignment;

  static TransitionInfo appDefault() => const TransitionInfo(hasTransition: false);
}

class RootPageContext {
  const RootPageContext(this.isRootPage, [this.errorRoute]);
  final bool isRootPage;
  final String? errorRoute;

  static bool isInactiveRootPage(BuildContext context) {
    final rootPageContext = context.read<RootPageContext?>();
    final isRootPage = rootPageContext?.isRootPage ?? false;
    final location = GoRouterState.of(context).uri.toString();
    return isRootPage && location != '/' && location != rootPageContext?.errorRoute;
  }

  static Widget wrap(Widget child, {String? errorRoute}) => Provider.value(
        value: RootPageContext(true, errorRoute),
        child: child,
      );
}

extension GoRouterLocationExtension on GoRouter {
  String getCurrentLocation() {
    final RouteMatch lastMatch = routerDelegate.currentConfiguration.last;
    final RouteMatchList matchList = lastMatch is ImperativeRouteMatch ? lastMatch.matches : routerDelegate.currentConfiguration;
    return matchList.uri.toString();
  }
}
