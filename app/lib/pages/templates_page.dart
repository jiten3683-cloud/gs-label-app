import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../services/db_service.dart';

class TemplatesPage extends StatefulWidget {
  const TemplatesPage({super.key});
  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> {
  List<Map<String, dynamic>> _rows = [];
  @override
  void initState() { super.initState(); _reload(); }

  Future<void> _reload() async {
    _rows = await context.read<DbService>().listTemplates();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd-MMM HH:mm');
    return RefreshIndicator(
      onRefresh: _reload,
      child: _rows.isEmpty
        ? const Center(child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('No templates yet. Create one in the Designer tab.')))
        : ListView.separated(
          itemCount: _rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final r = _rows[i];
            final updated = DateTime.fromMillisecondsSinceEpoch(
              r['updated'] as int);
            return ListTile(
              leading: const Icon(Icons.label),
              title: Text(r['name'] as String),
              subtitle: Text(
                '${r['width_mm']} × ${r['height_mm']} mm · '
                'updated ${fmt.format(updated)}'),
              trailing: const Icon(Icons.chevron_right),
            );
          }),
    );
  }
}
