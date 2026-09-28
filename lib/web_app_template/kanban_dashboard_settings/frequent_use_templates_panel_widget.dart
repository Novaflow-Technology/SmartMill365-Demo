import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:smartmachine365/components/card_widget/card_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/template_card_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';

const _kCardBg = Color.fromRGBO(0, 4, 51, 1);
const _kBorderRadius = 16.0;
const _kBaseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings';

BoxDecoration kanbanCardDecoration(BuildContext context) {
  final primary = FlutterFlowTheme.of(context).primary;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(_kBorderRadius),
    color: _kCardBg,
    border: Border.all(color: primary.withOpacity(0.4), width: 1),
    boxShadow: [
      BoxShadow(
        color: primary.withOpacity(0.08),
        blurRadius: 16,
        spreadRadius: 1,
      ),
    ],
  );
}

class FrequentUseTemplatesWidgetPanel extends StatefulWidget {
  final String? selectedTemplateId;
  final Function(String id, String title, String remark, Map<String, dynamic> fullData) onTemplateSelected;

  const FrequentUseTemplatesWidgetPanel({
    Key? key,
    required this.selectedTemplateId,
    required this.onTemplateSelected,
  }) : super(key: key);

  @override
  State<FrequentUseTemplatesWidgetPanel> createState() => FrequentUseTemplatesWidgetPanelState();
}

class FrequentUseTemplatesWidgetPanelState extends State<FrequentUseTemplatesWidgetPanel> {
  static const List<Map<String, dynamic>> _defaultTemplates = [
    {
      'id': 'blank',
      'label': 'Add Blank Kanban',
      'remark': 'Blank Kanban',
      'title': '',
      'layout': 'VERTICAL_4X3',
      'left': 'NONE',
      'right': 'TIME',
      'display': 'SCROLL',
      'interval': 20,
      'chartValue': false,
      'footer': false,
      'headerRows': 0,
      'footerRows': 0,
      'displayDefaultTitle': true,
      'showGrid': true,
      'createdAt': '',
      'userId': '',
      'isBlank': true,
    },
  ];

  List<Map<String, dynamic>> _fetchedTemplates = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchTemplates();
  }

  void refresh() => _fetchTemplates();

  Future<void> _fetchTemplates() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final response = await http.get(Uri.parse('$_kBaseUrl/list')).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonData = jsonDecode(response.body);
        final List<dynamic> templates = jsonData['data'] is List ? jsonData['data'] as List<dynamic> : [];

        final List<Map<String, dynamic>> converted = templates.map((template) {
          final t = template as Map<String, dynamic>;
          return {
            'id': t['id'] ?? '',
            'label': t['kanbanDesc'] ?? 'Untitled',
            'remark': t['remark'] ?? '',
            'title': t['title'] ?? '',
            'layout': t['layout'] ?? 'VERTICAL_4X3',
            'left': t['left'] ?? 'NONE',
            'right': t['right'] ?? 'TIME',
            'display': t['display'] ?? 'SCROLL',
            'interval': t['interval'] ?? 20,
            'chartValue': t['chartValue'] ?? false,
            'footer': t['footer'] ?? false,
            'headerRows': t['headerRows'] ?? 0,
            'footerRows': t['footerRows'] ?? 0,
            'displayDefaultTitle': t['displayDefaultTitle'] ?? false,
            'showGrid': t['showGrid'] ?? true,
            'interfaceType': t['interfaceType'] ?? 'KANBAN_GRID',
            'ecConfig': t['ecConfig'],
            'createdAt': t['createdAt'] ?? '',
            'userId': t['userId'] ?? '',
            'isBlank': false,
            'kanbanDesc': t['kanbanDesc'] ?? 'Untitled',
          };
        }).toList();

        setState(() {
          _fetchedTemplates = converted;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load templates (${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  // ── DELETE /:uid/template/:templateId ─────────────────────────────────────
  Future<void> _deleteTemplate(String templateId, String userId) async {
    final uid = userId.isNotEmpty ? userId : (AppStateNotifier.instance.uid ?? '');
    if (uid.isEmpty) {
      debugPrint('Cannot delete: uid is empty');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF00042E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text(
          'Delete Template',
          style: TextStyle(color: Colors.white, fontFamily: 'Poppins', fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'Are you sure you want to delete this template? This action cannot be undone.',
          style: TextStyle(color: Colors.white70, fontFamily: 'Poppins', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54, fontFamily: 'Poppins')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontFamily: 'Poppins', fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isLoading = true);

    try {
      final url = Uri.parse('$_kBaseUrl/$uid/template/$templateId');
      debugPrint('DELETE $url');

      final response = await http.delete(url, headers: {'Content-Type': 'application/json'}).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 204) {
        setState(() {
          _fetchedTemplates.removeWhere((t) => t['id'] == templateId);
          _isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Template deleted'), backgroundColor: Colors.green, duration: Duration(seconds: 2)),
          );
        }
      } else {
        final errMsg = (jsonDecode(response.body) as Map<String, dynamic>)['error'] ?? 'Unknown error';
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $errMsg'), backgroundColor: Colors.redAccent, duration: const Duration(seconds: 3)),
          );
        }
      }
    } catch (e) {
      debugPrint('Error deleting template: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error deleting template'), backgroundColor: Colors.redAccent, duration: Duration(seconds: 2)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> allTemplates = [
      ..._defaultTemplates,
      ..._fetchedTemplates.take(7),
    ];

    return LayoutBuilder(builder: (context, constraints) {
    final useFixedWidth = constraints.maxWidth > 300;
    return SizedBox(
      width: useFixedWidth ? 240 : double.infinity,
      child: CardWidget(
        glowColor: FlutterFlowTheme.of(context).primary,
        blurSigma: 2,
        topPadMultiplier: 0.6,
        bottomPadMultiplier: 0.6,
        armLenMultiplier: 0.5,
        builder: (context, sizing) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Frequent Use Template',
                  style: FlutterFlowTheme.of(context).labelMedium.override(
                        fontFamily: 'Poppins',
                        color: FlutterFlowTheme.of(context).primaryText,
                        fontWeight: FontWeight.w600,
                        font: GoogleFonts.poppins(),
                      ),
                ),
                if (_isLoading)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(FlutterFlowTheme.of(context).primary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 11, fontFamily: 'Poppins')),
              ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.85,
              ),
              itemCount: allTemplates.length,
              itemBuilder: (context, index) {
                final t = allTemplates[index];
                final selected = widget.selectedTemplateId == t['id'];
                final isBlank = t['isBlank'] as bool;

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    TemplateCardWidget(
                      id: t['id'] as String,
                      label: t['label'] as String,
                      remark: t['remark'] as String,
                      isBlank: isBlank,
                      isSelected: selected,
                      onTap: () {
                        widget.onTemplateSelected(
                          t['id'] as String,
                          t['title'] as String? ?? t['label'] as String,
                          t['remark'] as String,
                          t,
                        );
                      },
                    ),
                    if (!isBlank)
                      Positioned(
                        top: -6,
                        right: -6,
                        child: GestureDetector(
                          onTap: () => _deleteTemplate(
                            t['id'] as String,
                            t['userId'] as String? ?? '',
                          ),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                              border: Border.all(color: _kCardBg, width: 1.5),
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                            ),
                            child: const Icon(Icons.close, size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
    });
  }
}
