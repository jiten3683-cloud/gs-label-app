import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/db_service.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  List<Map<String, dynamic>> _products = [];
  String _search = '';

  @override
  void initState() { super.initState(); _reload(); }

  Future<void> _reload() async {
    _products = await context.read<DbService>().listProducts(
        search: _search.isEmpty ? null : _search);
    setState(() {});
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Delete Product'),
              content: Text('Delete "$name"? This cannot be undone.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete')),
              ],
            ));
    if (ok == true && mounted) {
      await context.read<DbService>().deleteProduct(id);
      _reload();
    }
  }

  void _openForm([Map<String, dynamic>? existing]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ProductForm(
        existing: existing,
        onSaved: _reload,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Product Master')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SearchBar(
              hintText: 'Search by name or SKU…',
              leading: const Icon(Icons.search),
              onChanged: (s) {
                _search = s;
                _reload();
              },
            ),
          ),
          Expanded(
            child: _products.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.inventory_2_outlined,
                            size: 64, color: Colors.grey),
                        const SizedBox(height: 12),
                        Text(_search.isEmpty
                            ? 'No products yet. Tap + to add one.'
                            : 'No products match "$_search"'),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _products.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 72),
                    itemBuilder: (_, i) {
                      final p = _products[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _categoryColor(
                              p['category'] as String? ?? ''),
                          child: Text(
                            (p['name'] as String).isNotEmpty
                                ? (p['name'] as String)[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        title: Text(p['name'] as String? ?? ''),
                        subtitle: Text(_subtitle(p)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Edit',
                              onPressed: () => _openForm(p),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red),
                              tooltip: 'Delete',
                              onPressed: () => _delete(
                                  p['id'] as int, p['name'] as String),
                            ),
                          ],
                        ),
                        onTap: () => _openForm(p),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Add Product'),
      ),
    );
  }

  String _subtitle(Map<String, dynamic> p) {
    final parts = <String>[];
    if ((p['purity'] as String? ?? '').isNotEmpty) parts.add(p['purity'] as String);
    if ((p['rate'] as num? ?? 0) > 0) {
      parts.add('₹${(p['rate'] as num).toStringAsFixed(0)}/g');
    }
    if ((p['hsn'] as String? ?? '').isNotEmpty) parts.add('HSN: ${p['hsn']}');
    return parts.isEmpty ? 'No details' : parts.join('  •  ');
  }

  Color _categoryColor(String cat) {
    switch (cat.toLowerCase()) {
      case 'gold':    return const Color(0xFFB8860B);
      case 'silver':  return Colors.blueGrey;
      case 'diamond': return Colors.lightBlue;
      default:        return Colors.teal;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ProductForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  const _ProductForm({this.existing, required this.onSaved});

  @override
  State<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<_ProductForm> {
  final _nameCtrl    = TextEditingController();
  final _codeCtrl    = TextEditingController();
  final _purityCtrl  = TextEditingController();
  final _hsnCtrl     = TextEditingController();
  final _rateCtrl    = TextEditingController();
  final _makingCtrl  = TextEditingController();
  String _category   = 'Gold';
  bool _saving = false;

  static const _categories = ['Gold', 'Silver', 'Diamond', 'Other'];
  static const _purities   = [
    '24K', '22K', '18K', '14K', '10K',
    '99.9', '99.5', '92.5', '80%', 'Custom',
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameCtrl.text   = e['name']     as String? ?? '';
      _codeCtrl.text   = e['code']     as String? ?? '';
      _purityCtrl.text = e['purity']   as String? ?? '';
      _hsnCtrl.text    = e['hsn']      as String? ?? '';
      _rateCtrl.text   = (e['rate']    as num? ?? 0).toString();
      _makingCtrl.text = (e['making']  as num? ?? 0).toString();
      _category        = e['category'] as String? ?? 'Gold';
      if (!_categories.contains(_category)) _category = 'Gold';
    }
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Product name is required')));
      return;
    }
    setState(() => _saving = true);
    final db = context.read<DbService>();
    await db.saveProduct(
      id:       widget.existing?['id'] as int?,
      name:     _nameCtrl.text.trim(),
      code:     _codeCtrl.text.trim(),
      category: _category,
      purity:   _purityCtrl.text.trim(),
      hsn:      _hsnCtrl.text.trim(),
      rate:     double.tryParse(_rateCtrl.text) ?? 0,
      making:   double.tryParse(_makingCtrl.text) ?? 0,
    );
    widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            widget.existing == null ? 'Add Product' : 'Edit Product',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          _tf(_nameCtrl,   'Product Name *', TextInputType.text),
          _tf(_codeCtrl,   'SKU / Code',     TextInputType.text),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(
                labelText: 'Category', border: OutlineInputBorder()),
            items: _categories
                .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                .toList(),
            onChanged: (v) => setState(() => _category = v ?? 'Gold'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _purities.contains(_purityCtrl.text)
                ? _purityCtrl.text
                : 'Custom',
            decoration: const InputDecoration(
                labelText: 'Purity', border: OutlineInputBorder()),
            items: _purities
                .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                .toList(),
            onChanged: (v) {
              if (v != null && v != 'Custom') {
                setState(() => _purityCtrl.text = v);
              }
            },
          ),
          const SizedBox(height: 12),
          _tf(_purityCtrl, 'Purity (custom override)', TextInputType.text),
          _tf(_hsnCtrl,    'HSN Code',           TextInputType.number),
          Row(children: [
            Expanded(child: _tf(_rateCtrl,  'Rate/gram (₹)', TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(child: _tf(_makingCtrl,'Making (%)',    TextInputType.number)),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 18, width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(widget.existing == null
                      ? 'Add Product' : 'Update Product'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tf(TextEditingController ctrl, String label,
      TextInputType type) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: ctrl,
          keyboardType: type,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
        ),
      );
}