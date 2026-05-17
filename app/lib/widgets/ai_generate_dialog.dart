import 'package:flutter/material.dart';

import '../services/ai_service.dart';

/// Modal that asks the operator to describe the label in natural language,
/// calls AiService.generate, and returns the resulting list of element maps
/// (or null if the user cancelled).
///
/// Usage from designer_page.dart:
///
///   final result = await showDialog<List<Map<String,dynamic>>>(
///     context: context,
///     builder: (_) => AiGenerateDialog(widthMm: _wMm, heightMm: _hMm),
///   );
///   if (result != null) _replaceElements(result);
class AiGenerateDialog extends StatefulWidget {
  final int widthMm;
  final int heightMm;
  const AiGenerateDialog(
      {super.key, required this.widthMm, required this.heightMm});

  @override
  State<AiGenerateDialog> createState() => _AiGenerateDialogState();
}

class _AiGenerateDialogState extends State<AiGenerateDialog> {
  final _ai     = AiService();
  final _ctrl   = TextEditingController();
  bool   _busy  = false;
  AiResult? _last;

  // Common starting points the user can tap to fill the prompt box.
  static const _examples = <String>[
    'Gold ring 22K with net weight, serial and QR code',
    'Silver chain — gross, net, purity and barcode',
    'Bangle 24K with weight, date and serial',
    'Pure gold coin 999 with weight and serial',
    'Gold bar 1 tola with weight, serial, date and barcode',
  ];

  Future<void> _go() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() { _busy = true; _last = null; });
    final r = await _ai.generate(
        prompt: text, widthMm: widget.widthMm, heightMm: widget.heightMm);
    if (!mounted) return;
    setState(() { _busy = false; _last = r; });
  }

  void _accept() {
    if (_last == null) return;
    Navigator.of(context).pop(_last!.elements);
  }

  Future<void> _openApiKeyDialog() async {
    final current = await _ai.getKey();
    final ctrl    = TextEditingController(text: current ?? '');
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Claude API key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Paste your Anthropic API key (starts with "sk-ant-…"). '
            'Get one at console.anthropic.com.\n\n'
            'Leave blank to use the offline rule-based generator only.',
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
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      final v = ctrl.text.trim();
      if (v.isEmpty) { await _ai.clearKey(); }
      else           { await _ai.setKey(v); }
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.auto_awesome, color: Colors.amber),
              const SizedBox(width: 8),
              Text('AI Label Generator',
                  style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.key),
                tooltip: 'Set Claude API key',
                onPressed: _openApiKeyDialog,
              ),
              IconButton(icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context)),
            ]),
            const SizedBox(height: 4),
            Text(
              'Label size: ${widget.widthMm} × ${widget.heightMm} mm',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),

            // Prompt box
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLines: 3, minLines: 2,
              decoration: const InputDecoration(
                labelText: 'Describe your label',
                hintText: 'e.g. "Gold ring 22K with net weight, serial and QR"',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),

            // Quick-pick examples
            Wrap(spacing: 6, runSpacing: 6, children: _examples.map((e) =>
              ActionChip(
                avatar: const Icon(Icons.bolt, size: 14),
                label: Text(e, style: const TextStyle(fontSize: 11)),
                onPressed: _busy ? null : () { _ctrl.text = e; _go(); },
              )).toList()),
            const SizedBox(height: 16),

            // Generate button + status
            Row(children: [
              FutureBuilder<bool>(
                future: _ai.hasKey,
                builder: (_, snap) {
                  final has = snap.data == true;
                  return Chip(
                    avatar: Icon(has ? Icons.cloud_done : Icons.cloud_off, size: 14,
                        color: has ? Colors.green : Colors.grey),
                    label: Text(has ? 'Claude key set' : 'Offline (rule-based)',
                        style: const TextStyle(fontSize: 11)),
                  );
                },
              ),
              const SizedBox(width: 8),
              if (_last != null)
                Chip(
                  avatar: const Icon(Icons.auto_awesome, size: 14),
                  label: Text(_last!.sourceLabel,
                      style: const TextStyle(fontSize: 11)),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _busy ? null : _go,
                icon: _busy
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            color: Colors.white))
                    : const Icon(Icons.auto_awesome),
                label: Text(_busy ? 'Generating…' : 'Generate'),
              ),
            ]),

            // Result
            if (_last != null) ...[
              const Divider(height: 24),
              Text('Generated ${_last!.elements.length} element(s):',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Wrap(spacing: 6, runSpacing: 4, children:
                    _last!.elements.map((e) => Chip(
                      label: Text('${e['t']} @ ${e['x']},${e['y']}',
                          style: const TextStyle(fontSize: 10)))).toList()),
                ),
              ),
              if (_last!.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('AI error: ${_last!.error}',
                      style: const TextStyle(color: Colors.orange, fontSize: 11)),
                ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: OutlinedButton(
                    onPressed: _busy ? null : _go,
                    child: const Text('Regenerate'))),
                const SizedBox(width: 8),
                Expanded(child: FilledButton.icon(
                    onPressed: _accept,
                    icon: const Icon(Icons.check),
                    label: const Text('Use this'))),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}
