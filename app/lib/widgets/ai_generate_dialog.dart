import 'package:flutter/material.dart';

import '../services/ai_service.dart';

class AiGenerateDialog extends StatefulWidget {
  final int widthMm;
  final int heightMm;
  const AiGenerateDialog({super.key, required this.widthMm, required this.heightMm});

  @override
  State<AiGenerateDialog> createState() => _AiGenerateDialogState();
}

class _AiGenerateDialogState extends State<AiGenerateDialog> {
  final _ai   = AiService();
  final _ctrl = TextEditingController();
  bool      _busy = false;
  AiResult? _last;

  static const _examples = [
    'Gold ring 22K with net weight, serial and QR code',
    'Silver chain — gross, net, purity and barcode',
    'Bangle 24K with weight, date and serial',
    'Pure gold coin 999 with weight and serial',
    'Gold bar 1 tola with weight, serial, date and barcode',
  ];

  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _generate() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() { _busy = true; _last = null; });
    final r = await _ai.generate(
        prompt: text, widthMm: widget.widthMm, heightMm: widget.heightMm);
    if (!mounted) return;
    setState(() { _busy = false; _last = r; });
  }

  Future<void> _openKeyDialog() async {
    final current = await _ai.getKey();
    if (!mounted) return;
    final ctrl = TextEditingController(text: current ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Claude API Key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Paste your Anthropic API key (starts with "sk-ant-…").\n'
            'Get one free at console.anthropic.com\n\n'
            'Leave blank to use the offline pattern generator.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl, obscureText: true, autofocus: true,
            decoration: const InputDecoration(
                hintText: 'sk-ant-...', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    final v = ctrl.text.trim();
    ctrl.dispose();
    if (ok == true && mounted) {
      if (v.isEmpty) await _ai.clearKey(); else await _ai.setKey(v);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenH * 0.85, maxWidth: 560),
        child: Column(children: [

          // ── Fixed header ──────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(children: [
              const Icon(Icons.auto_awesome, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('AI Label Generator',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text('${widget.widthMm} × ${widget.heightMm} mm',
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              IconButton(
                icon: const Icon(Icons.key_outlined),
                tooltip: 'Set API key',
                onPressed: _openKeyDialog,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),

          // ── Scrollable body ───────────────────────────────────────────────
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

              // Prompt field
              TextField(
                controller: _ctrl,
                autofocus: true,
                maxLines: 3, minLines: 2,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _generate(),
                decoration: InputDecoration(
                  labelText: 'Describe your label',
                  hintText: 'e.g. Gold ring 22K with weight, serial and QR code',
                  border: const OutlineInputBorder(),
                  suffixIcon: _ctrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () { _ctrl.clear(); setState(() {}); })
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),

              // ── GENERATE BUTTON — always visible ─────────────────────────
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: (_busy || _ctrl.text.trim().isEmpty) ? null : _generate,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.auto_awesome),
                  label: Text(_busy ? 'Generating…' : 'Generate Label',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 14),

              // API key status chip
              FutureBuilder<bool>(
                future: _ai.hasKey,
                builder: (_, snap) {
                  final has = snap.data == true;
                  return Row(children: [
                    Icon(has ? Icons.cloud_done : Icons.cloud_off,
                        size: 14, color: has ? Colors.green : Colors.grey),
                    const SizedBox(width: 6),
                    Text(
                      has ? 'Claude AI key set — tap key icon to change'
                           : 'No API key — using offline pattern generator',
                      style: TextStyle(fontSize: 11,
                          color: has ? Colors.green.shade700 : Colors.grey.shade600),
                    ),
                  ]);
                },
              ),
              const SizedBox(height: 14),

              // Quick-pick example chips
              const Text('Quick examples — tap to fill & generate:',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: _examples.map((e) =>
                ActionChip(
                  avatar: const Icon(Icons.bolt, size: 14),
                  label: Text(e, style: const TextStyle(fontSize: 11)),
                  onPressed: _busy ? null : () {
                    _ctrl.text = e;
                    setState(() {});
                    _generate();
                  },
                )).toList()),

              // Result section
              if (_last != null) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Row(children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
                  const SizedBox(width: 6),
                  Text('Generated ${_last!.elements.length} element(s)',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_last!.sourceLabel,
                        style: TextStyle(fontSize: 10, color: Colors.amber.shade800)),
                  ),
                ]),
                const SizedBox(height: 6),
                Wrap(spacing: 4, runSpacing: 4,
                  children: _last!.elements.map((e) => Chip(
                    label: Text('${e['t']} (${e['x']},${e['y']})',
                        style: const TextStyle(fontSize: 10)),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  )).toList()),
                if (_last!.error != null) ...[
                  const SizedBox(height: 6),
                  Text('Note: ${_last!.error}',
                      style: const TextStyle(color: Colors.orange, fontSize: 11)),
                ],
              ],
              const SizedBox(height: 8),
            ]),
          )),

          // ── Fixed footer buttons ──────────────────────────────────────────
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              )),
              if (_last != null) ...[
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton.icon(
                  onPressed: _busy ? null : _generate,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                )),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, _last!.elements),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Use this Template'),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
