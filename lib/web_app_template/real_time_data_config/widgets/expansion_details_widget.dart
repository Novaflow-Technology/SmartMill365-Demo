import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import '../cubits/live_stream_cubit.dart';
import '../models/discovery_models.dart';

class ExpansionDetailsWidget extends StatefulWidget {
  final DiscoveredDevice device;

  const ExpansionDetailsWidget({super.key, required this.device});

  @override
  State<ExpansionDetailsWidget> createState() => _ExpansionDetailsWidgetState();
}

class _ExpansionDetailsWidgetState extends State<ExpansionDetailsWidget> {
  late LiveStreamCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = LiveStreamCubit();
    _cubit.startStreaming(widget.device.tags);
  }

  @override
  void didUpdateWidget(ExpansionDetailsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldTags = oldWidget.device.tags;
    final newTags = widget.device.tags;
    if (newTags.isNotEmpty &&
        (oldTags.isEmpty || newTags.length != oldTags.length)) {
      _cubit.startStreaming(newTags);
    }
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LiveStreamCubit, LiveStreamState>(
      bloc: _cubit,
      builder: (context, state) {
        return Container(
          margin: const EdgeInsets.fromLTRB(32, 0, 16, 8),
          decoration: BoxDecoration(
            color: const Color(0xFF010820),
            border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.25)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sub-header
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Row(
                  children: [
                    const Icon(Icons.sensors, color: Color(0xFF00D4FF), size: 14),
                    const SizedBox(width: 8),
                    Text(
                      'Live Tags — ${widget.device.displayName}',
                      style: GoogleFonts.outfit(
                        color: const Color(0xFF00D4FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    if (state.isLoading)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF39FF14)),
                      )
                    else
                      Text(
                        state.lastUpdate != null
                            ? 'Updated ${state.lastUpdate!.toLocal().toString().substring(11, 19)}'
                            : '',
                        style: GoogleFonts.poppins(
                            color: Colors.white24, fontSize: 10),
                      ),
                  ],
                ),
              ),
              // Column headers
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                color: const Color(0xFF00D4FF).withOpacity(0.05),
                child: Row(
                  children: [
                    _ColH('Tag Name', flex: 3),
                    _ColH('Channels (Field)', flex: 3),
                    _ColH('Measurement', flex: 2),
                    _ColH('Unit', flex: 1),
                    _ColH('Status', flex: 2),
                    _ColH('Value', flex: 2),
                  ],
                ),
              ),
              const Divider(
                  color: Color(0xFF00D4FF), height: 1, thickness: 0.2),
              // Rows
              ...widget.device.tags.map((tag) {
                final key = '${tag.measurement}.${tag.realMeasurement}.${tag.fieldName}';
                final value = state.values[key];
                final displayValue =
                    (value != null && value.toString().isNotEmpty)
                        ? value.toString()
                        : null;
                final isStale = state.isStale(key);
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color:
                                const Color(0xFF00D4FF).withOpacity(0.08))),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          tag.tagName.isNotEmpty ? tag.tagName : tag.fieldName,
                          style: GoogleFonts.poppins(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(tag.fieldName,
                            style: GoogleFonts.poppins(
                                color: Colors.white38, fontSize: 11)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(tag.realMeasurement.isEmpty ? '—' : tag.realMeasurement,
                            style: GoogleFonts.poppins(
                                color: Colors.white54, fontSize: 11)),
                      ),
                      Expanded(
                        flex: 1,
                        child: Text(tag.unit,
                            style: GoogleFonts.poppins(
                                color: Colors.white38, fontSize: 11)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isStale
                                    ? Colors.red
                                    : const Color(0xFF39FF14),
                                boxShadow: [
                                  BoxShadow(
                                    color: isStale
                                        ? Colors.red.withOpacity(0.5)
                                        : const Color(0xFF39FF14)
                                            .withOpacity(0.5),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isStale ? 'Stale' : 'Live',
                              style: GoogleFonts.poppins(
                                color: isStale
                                    ? Colors.red
                                    : const Color(0xFF39FF14),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          displayValue ?? '—',
                          style: GoogleFonts.poppins(
                            color: displayValue != null
                                ? const Color(0xFF39FF14)
                                : Colors.white24,
                            fontWeight: displayValue != null
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }
}

class _ColH extends StatelessWidget {
  final String text;
  final int flex;
  const _ColH(this.text, {required this.flex});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(text,
          style: GoogleFonts.poppins(
              color: const Color(0xFF00D4FF),
              fontSize: 10,
              fontWeight: FontWeight.bold)),
    );
  }
}
