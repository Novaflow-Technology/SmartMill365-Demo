import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '/flutter_flow/flutter_flow_theme.dart';
import '../../../../components/dialogs/custom_dialog.dart';
import '../../../../components/data_table/data_table_widget.dart';
import '../../../../components/data_table/table_column.dart';
import 'package:smartmachine365/web_app_template/manage_user_groups/group/add.dart';
import 'package:smartmachine365/web_app_template/manage_user_groups/group/edit.dart';

class GroupView extends StatefulWidget {
  final String userRole;
  final String userName;
  const GroupView({super.key, required this.userName, required this.userRole});

  @override
  _GroupViewState createState() => _GroupViewState();
}

class _GroupViewState extends State<GroupView> {
  List<Map<String, dynamic>> groups = [];
  Map<String, String> groupSizes = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    fetchGroups();
  }

  Future<void> fetchGroups() async {
    setState(() => _isLoading = true);
    try {
      final groupsUrl =
          Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/groups/');
      final groupsResponse = await http.get(groupsUrl);
      if (groupsResponse.statusCode != 200) {
        throw Exception('Error fetching groups: ${groupsResponse.body}');
      }
      final List<dynamic> fetchedGroups = jsonDecode(groupsResponse.body);

      Map<String, String> sizes = {};
      await Future.wait(
        fetchedGroups.map((group) async {
          try {
            final groupId = group['id'];
            final sizeUrl = Uri.parse(
                'https://us-central1-smartmill365-demo.cloudfunctions.net/api/groups/size/$groupId');
            final sizeResponse = await http.get(sizeUrl);
            if (sizeResponse.statusCode == 200) {
              final sizeJson = jsonDecode(sizeResponse.body);
              sizes[groupId] = sizeJson['groupSize'].toString();
            } else {
              sizes[groupId] = '0';
            }
          } catch (e) {
            sizes[group['id']] = '0';
          }
        }),
      );

      setState(() {
        groupSizes = sizes;
        groups = fetchedGroups
            .map((g) => Map<String, dynamic>.from(g as Map))
            .toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$e', style: const TextStyle(color: Colors.red)),
            backgroundColor: Colors.black,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> deleteGroup(String id) async {
    try {
      final url =
          Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/groups/delete/$id');
      final response = await http.delete(url);
      if (response.statusCode == 200) {
        setState(() {
          groups.removeWhere((group) => group['id'] == id);
          groupSizes.remove(id);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Group deleted successfully!',
                  style: TextStyle(color: Colors.green)),
              backgroundColor: Colors.black,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        throw Exception(jsonDecode(response.body)['error']);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$e', style: const TextStyle(color: Colors.red)),
            backgroundColor: Colors.black,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showAddGroupDialog(BuildContext context) {
    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (_) => AddGroupDialog(
        userName: widget.userName,
        onGroupAdded: fetchGroups,
      ),
    );
  }

  void _showEditGroupDialog(BuildContext context, Map<String, dynamic> group) {
    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (_) => EditGroupDialog(
        id: group['id'],
        initialName: group['name'],
        initialDescription: group['description'],
        userName: widget.userName,
        onGroupAdded: fetchGroups,
      ),
    );
  }

  Widget _buildCustomHeader(BuildContext context) {
    final t = FlutterFlowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 25),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Group Management',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: t.primaryText,
                  fontFamily: 'Poppins',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Create and manage permission groups for user access control.',
                style: TextStyle(
                  fontSize: 14,
                  color: t.secondaryText,
                  fontFamily: 'Poppins',
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                '${widget.userRole.isNotEmpty ? widget.userRole : 'User'}: ${widget.userName}',
                style: TextStyle(
                  color: t.primaryText,
                  fontFamily: 'Poppins',
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                backgroundColor: const Color(0xFF9C27B0),
                child: Text(
                  _getInitials(widget.userName),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getInitials(String name) {
    if (name.trim().isEmpty) return '??';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    return parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = FlutterFlowTheme.of(context);

    final List<Map<String, dynamic>> structuredRows = groups.map((g) {
      final m = Map<String, dynamic>.from(g);
      m['_size'] = groupSizes[g['id']] ?? '0';
      m['_created'] = g['created_at'] != null
          ? g['created_at'].toString().replaceAll('T', ' ').substring(0, 19)
          : 'Unknown';
      return m;
    }).toList();

    return Stack(
      children: [
        Container(
          color: t.primaryBackground,
          child: Column(
            children: [
              _buildCustomHeader(context),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20.0, vertical: 10.0),
                  child: DataTableWidget(
                    columns: const [
                      TableColumn('GROUP NAME', 'name', 200, sortable: true),
                      TableColumn('DESCRIPTION', 'description', 280),
                      TableColumn('SIZE', '_size', 100, sortable: true),
                      TableColumn('ASSIGN BY', 'assignby', 160, sortable: true),
                      TableColumn('CREATED AT', '_created', 180, sortable: true),
                    ],
                    rows: structuredRows,
                    primaryKey: 'id',
                    primaryIcon: Icons.group_outlined,
                    onEdit: (row) => _showEditGroupDialog(context, row),
                    onDelete: (row) {
                      showDialog(
                        context: context,
                        builder: (_) => CustomDialog(
                          icon: Icons.delete_outline,
                          title: 'Confirm Deletion',
                          subtitle:
                              'Are you sure you want to remove this group?',
                          sections: const [
                            CustomDialogSection(
                              title: 'Warning',
                              subtitle:
                                  'This will permanently remove the group and unassign all users from it. This action cannot be undone.',
                              children: [],
                            ),
                          ],
                          submitLabel: 'REMOVE',
                          cancelLabel: 'CANCEL',
                          onSubmit: () async {
                            await deleteGroup(row['id'].toString());
                            return true;
                          },
                        ),
                      );
                    },
                    actions: [
                      TableAction(
                        label: 'Refresh',
                        icon: Icons.refresh,
                        onTap: fetchGroups,
                      ),
                      TableAction(
                        label: 'Add Group',
                        icon: Icons.add,
                        isPrimary: true,
                        onTap: () => _showAddGroupDialog(context),
                      ),
                    ],
                    cellBuilder: (key, value, row) {
                      if (key == 'name') {
                        final name = row['name']?.toString() ?? '';
                        final id = row['id']?.toString() ?? '';
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: t.tertiary.withOpacity(0.18),
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: t.tertiary.withOpacity(0.5),
                                    width: 1.5),
                              ),
                              child: Center(
                                child: Text(
                                  _getInitials(name),
                                  style: TextStyle(
                                    color: t.tertiary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    name,
                                    style: TextStyle(
                                      color: t.primaryText,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'ID: #${id.padLeft(5, '0')}',
                                    style: TextStyle(
                                      color: t.secondaryText,
                                      fontSize: 11,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      }

                      if (key == '_size') {
                        final size = value;
                        final color =
                            int.tryParse(size) != null && int.parse(size) > 0
                                ? t.success
                                : t.secondaryText;
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: color.withOpacity(0.5), width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.people_outline,
                                    size: 14, color: color),
                                const SizedBox(width: 6),
                                Text(
                                  '$size members',
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      if (key == 'assignby') {
                        return Text(
                          value.isNotEmpty ? value : 'Unknown',
                          style: TextStyle(
                            color: t.primaryText,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        );
                      }

                      if (key == '_created') {
                        return Row(
                          children: [
                            Icon(Icons.calendar_today_outlined,
                                size: 13, color: t.secondaryText),
                            const SizedBox(width: 6),
                            Text(
                              value,
                              style: TextStyle(
                                color: t.secondaryText,
                                fontSize: 12,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        );
                      }

                      return null;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_isLoading)
          Positioned.fill(
            child: Center(
              child: CircularProgressIndicator(color: t.primary),
            ),
          ),
      ],
    );
  }
}
