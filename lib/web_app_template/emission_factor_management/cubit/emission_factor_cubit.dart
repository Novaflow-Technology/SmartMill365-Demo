import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;

import '/backend/schema/emission_factor_record.dart';
import '/backend/schema/emission_factor_audit_record.dart';
import 'emission_factor_state.dart';
import '../emission_factor_model.dart';

class EmissionFactorCubit extends Cubit<EmissionFactorState> {
  static const _apiBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static const _headers = {'Content-Type': 'application/json'};

  StreamSubscription<QuerySnapshot>? _factorsSub;
  StreamSubscription<QuerySnapshot>? _auditSub;

  List<EmissionFactor> _factors = [];
  List<AuditLogEntry> _auditLog = [];

  EmissionFactorCubit() : super(const EmissionFactorInitial()) {
    _subscribeToStreams();
  }

  // ── Firestore → model converters ──────────────────────────────────────────

  static EmissionFactor _recordToFactor(EmissionFactorRecord r) {
    return EmissionFactor(
      id: r.reference.id,
      fiscalYear: r.fiscalYear,
      factor: r.factor,
      source: r.source,
      carbonCost: r.carbonCost,
      sourceChipLabel: r.sourceChipLabel,
      publishedDate: r.publishedDate,
      effectiveFrom: r.effectiveFrom,
      status: _parseStatus(r.status),
      isRestated: r.isRestated,
      isPending: r.isPending,
      documentReference: r.documentReference,
      notes: r.notes,
    );
  }

  static AuditLogEntry _recordToAudit(EmissionFactorAuditRecord r) {
    return AuditLogEntry(
      timestamp: r.timestamp,
      action: _parseAction(r.action),
      fiscalYear: r.fiscalYear,
      fromValue: r.fromValue,
      toValue: r.toValue,
      actor: r.actor,
    );
  }

  static FactorStatus _parseStatus(String s) {
    switch (s) {
      case 'active':
        return FactorStatus.active;
      case 'locked':
        return FactorStatus.locked;
      default:
        return FactorStatus.draft;
    }
  }

  static AuditAction _parseAction(String s) {
    switch (s) {
      case 'activated':
        return AuditAction.activated;
      case 'deactivated':
        return AuditAction.deactivated;
      case 'autoLocked':
        return AuditAction.autoLocked;
      case 'restated':
        return AuditAction.restated;
      case 'updated':
        return AuditAction.updated;
      default:
        return AuditAction.created;
    }
  }

  // ── Real-time subscriptions (read path stays on Firestore directly) ────────

  void _subscribeToStreams({bool emitLoading = true}) {
    if (emitLoading) emit(const EmissionFactorLoading());

    _factorsSub = EmissionFactorRecord.collection
        .orderBy('fiscal_year', descending: true)
        .snapshots()
        .listen(
      (snap) {
        _factors = snap.docs
            .map((d) => _recordToFactor(EmissionFactorRecord.fromSnapshot(d)))
            .toList();
        _emitLoaded();
      },
      onError: (e) => emit(EmissionFactorError(e.toString())),
    );

    _auditSub = EmissionFactorAuditRecord.collection
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen(
      (snap) {
        _auditLog = snap.docs
            .map((d) =>
                _recordToAudit(EmissionFactorAuditRecord.fromSnapshot(d)))
            .toList();
        _emitLoaded();
      },
      onError: (e) => emit(EmissionFactorError(e.toString())),
    );
  }

  void _emitLoaded({bool isSaving = false}) {
    emit(EmissionFactorLoaded(
      factors: List.unmodifiable(_factors),
      auditLog: List.unmodifiable(_auditLog),
      isSaving: isSaving,
    ));
  }

  // ── API mutations ──────────────────────────────────────────────────────────

  /// Create a new emission factor. Returns true on success.
  Future<bool> saveEmissionFactor({
    required int fiscalYear,
    required double factor,
    required String source,
    double? carbonCost,
    required DateTime publishedDate,
    required DateTime effectiveFrom,
    required String documentReference,
    String? notes,
    required bool activate,
    required String actorEmail,
  }) async {
    _emitLoaded(isSaving: true);
    try {
      final body = json.encode({
        'fiscal_year': fiscalYear,
        'factor': factor,
        'source': source,
        'carbon_cost': carbonCost,
        'source_chip_label': 'ST Malaysia $fiscalYear',
        'published_date': publishedDate.toIso8601String(),
        'effective_from': effectiveFrom.toIso8601String(),
        'status': activate ? 'active' : 'draft',
        'document_reference': documentReference,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        'actor': actorEmail,
      });

      // Check if doc already exists; use PUT if so, POST /add if new.
      final docId = 'fy$fiscalYear';
      final existing = _factors.any((f) => f.fiscalYear == fiscalYear);

      http.Response res;
      if (existing) {
        res = await http.put(
          Uri.parse('$_apiBase/emission-factors/$docId'),
          headers: _headers,
          body: body,
        );
      } else {
        res = await http.post(
          Uri.parse('$_apiBase/emission-factors/add'),
          headers: _headers,
          body: body,
        );
      }

      if (res.statusCode == 200 || res.statusCode == 201) {
        return true;
      }
      final err = json.decode(res.body)['error'] ?? 'Unknown error';
      _emitLoaded();
      emit(EmissionFactorError(err.toString()));
      return false;
    } catch (e) {
      _emitLoaded();
      emit(EmissionFactorError(e.toString()));
      return false;
    }
  }

  /// Activate an existing draft factor via the API.
  Future<void> activateFactor(EmissionFactor factor, String actorEmail) async {
    if (factor.status != FactorStatus.draft) return;
    _emitLoaded(isSaving: true);
    try {
      final docId = 'fy${factor.fiscalYear}';
      final res = await http.put(
        Uri.parse('$_apiBase/emission-factors/$docId/activate'),
        headers: _headers,
        body: json.encode({'actor': actorEmail}),
      );
      if (res.statusCode != 200) {
        final err = json.decode(res.body)['error'] ?? 'Activation failed';
        _emitLoaded();
        emit(EmissionFactorError(err.toString()));
      }
    } catch (e) {
      _emitLoaded();
      emit(EmissionFactorError(e.toString()));
    }
  }

  /// Delete a factor via the API.
  Future<void> deleteFactor(EmissionFactor factor, String actorEmail) async {
    _emitLoaded(isSaving: true);
    try {
      final docId = 'fy${factor.fiscalYear}';
      final req = http.Request(
        'DELETE',
        Uri.parse('$_apiBase/emission-factors/$docId'),
      )
        ..headers.addAll(_headers)
        ..body = json.encode({'actor': actorEmail});
      final streamed = await req.send();
      if (streamed.statusCode != 200) {
        _emitLoaded();
        emit(const EmissionFactorError('Delete failed'));
      }
    } catch (e) {
      _emitLoaded();
      emit(EmissionFactorError(e.toString()));
    }
  }

  /// Delete all emission factors and audit entries. Requires intentional call.
  Future<void> clearAllData() async {
    _emitLoaded(isSaving: true);
    try {
      final res = await http.delete(
        Uri.parse('$_apiBase/emission-factors/clear-all'),
        headers: _headers,
        body: json.encode({'confirm': 'CLEAR_ALL'}),
      );
      if (res.statusCode != 200) {
        _emitLoaded();
        emit(EmissionFactorError(
          json.decode(res.body)['error'] ?? 'Clear failed',
        ));
      }
    } catch (e) {
      _emitLoaded();
      emit(EmissionFactorError(e.toString()));
    }
  }

  /// Re-subscribe to Firestore streams to force a fresh fetch.
  void refresh() {
    _factorsSub?.cancel();
    _auditSub?.cancel();
    _subscribeToStreams(emitLoading: false);
  }

  @override
  Future<void> close() {
    _factorsSub?.cancel();
    _auditSub?.cancel();
    return super.close();
  }
}
