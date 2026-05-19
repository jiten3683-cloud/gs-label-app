import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl, canLaunchUrl;

import '../services/license_service.dart';
import 'home_shell.dart';

const _supportPhone  = '+919828023683';
const _supportEmail  = 'jbcorporation214@yahoo.com';
const _kTrialDays    = 3;

class LoginPage extends StatefulWidget {
  final LicenseService license;
  const LoginPage({super.key, required this.license});
  @override State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _keyCtrl  = TextEditingController();
  final _wbCtrl   = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool  _loading      = false;
  bool  _verifying    = false; // true while doing startup license check
  bool  _networkError = false; // true when verify failed due to no internet
  String _error       = '';
  bool  _showActivation = false;

  LicenseService get _lic => widget.license;

  @override void initState() {
    super.initState();
    _keyCtrl.text = _lic.cachedLicenseKey;
    _wbCtrl.text  = _lic.cachedWeighBridgeId;
    if (_lic.isActivated) {
      _verifying = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _verifyAndProceed());
    }
  }

  Future<void> _verifyAndProceed() async {
    setState(() { _verifying = true; _networkError = false; _error = ''; });
    final err = await _lic.verifyOnline();
    if (!mounted) return;
    if (err == null) {
      _proceed();
    } else if (err.startsWith(LicenseService.networkErrorPrefix)) {
      // Network failure — don't deactivate, let user retry
      setState(() {
        _verifying    = false;
        _networkError = true;
        _error        = err.substring(LicenseService.networkErrorPrefix.length);
      });
    } else {
      // License rejected by server — deactivate and show activation form
      await _lic.deactivate();
      setState(() {
        _verifying      = false;
        _networkError   = false;
        _error          = err;
        _showActivation = true;
      });
    }
  }

  @override void dispose() {
    _keyCtrl.dispose(); _wbCtrl.dispose(); _codeCtrl.dispose();
    super.dispose();
  }

  void _proceed() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => HomeShell(license: _lic)));
  }

  Future<void> _activate() async {
    final key  = _keyCtrl.text.trim();
    final wb   = _wbCtrl.text.trim();
    final code = _lic.isDeviceBound ? null : _codeCtrl.text.trim();

    if (key.isEmpty || wb.isEmpty) {
      setState(() => _error = 'License Key and WeighBridge ID are required');
      return;
    }
    if (!_lic.isDeviceBound && (code == null || code.isEmpty)) {
      setState(() => _error = 'Activation Code is required for new device');
      return;
    }
    setState(() { _loading = true; _error = ''; });
    final err = await _lic.activate(
        licenseKey: key, weighBridgeId: wb, activationCode: code);
    if (!mounted) return;
    if (err == null) {
      _proceed();
    } else {
      setState(() { _error = err; _loading = false; });
    }
  }

  void _useTrial() {
    if (_lic.isTrialActive) _proceed();
  }

  Future<void> _callSupport() async {
    final uri = Uri.parse('tel:$_supportPhone');
    if (await canLaunchUrl(uri)) launchUrl(uri);
  }

  Future<void> _emailSupport() async {
    final uri = Uri.parse('mailto:$_supportEmail?subject=JBC-GS-PRINTER License');
    if (await canLaunchUrl(uri)) launchUrl(uri);
  }

  Future<void> _copyDeviceId() async {
    await Clipboard.setData(ClipboardData(text: _lic.deviceId));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device ID copied'), duration: Duration(seconds: 2)));
  }

  @override Widget build(BuildContext context) {
    final cs    = Theme.of(context).colorScheme;
    final state = _lic.state;

    // Show verifying screen while checking license with server
    if (_verifying) {
      return Scaffold(
        backgroundColor: cs.surface,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text('Verifying license…',
                style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.6))),
          ]),
        ),
      );
    }

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(height: 20),

            // ── Logo / Brand ─────────────────────────────────────────────────
            Container(
              width: 90, height: 90,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(
                    color: cs.primary.withOpacity(0.25),
                    blurRadius: 20, spreadRadius: 4)],
              ),
              child: Icon(Icons.label_important, size: 48, color: cs.primary),
            ),
            const SizedBox(height: 16),
            Text('JBC-GS-PRINTER',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,
                    color: cs.primary, letterSpacing: 1.5)),
            Text('Gold & Silver Label System',
                style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.6))),
            const SizedBox(height: 28),

            // ── Network Error Banner (startup verify failed — no internet) ──
            if (_networkError)
              Card(
                color: Colors.orange.shade100,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.wifi_off, color: Colors.orange.shade800),
                      const SizedBox(width: 8),
                      Text('NO INTERNET',
                          style: TextStyle(fontWeight: FontWeight.bold,
                              color: Colors.orange.shade800)),
                    ]),
                    const SizedBox(height: 8),
                    Text(_error,
                        style: TextStyle(fontSize: 12, color: Colors.orange.shade900)),
                    const SizedBox(height: 12),
                    SizedBox(width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _verifyAndProceed,
                        icon: const Icon(Icons.refresh),
                        label: const Text('RETRY'),
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.orange.shade700),
                      ),
                    ),
                  ]),
                ),
              ),

            // ── Trial Banner ─────────────────────────────────────────────────
            if (state == LicenseState.trial && !_networkError)
              _TrialBanner(
                daysLeft: _lic.trialDaysRemaining,
                onUseTrial: _useTrial,
                onActivate: () => setState(() => _showActivation = true),
              ),

            // ── Expired Banner ───────────────────────────────────────────────
            if (state == LicenseState.trialExpired && !_showActivation && !_networkError)
              _ExpiredBanner(
                onActivate: () => setState(() => _showActivation = true),
                onCall: _callSupport,
                onEmail: _emailSupport,
              ),

            // ── Activation Form ──────────────────────────────────────────────
            if (_showActivation || state == LicenseState.trialExpired) ...[
              const SizedBox(height: 16),
              Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    Text('License Activation',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                            color: cs.primary)),
                    const SizedBox(height: 16),
                    _field(_keyCtrl, 'License Key', Icons.vpn_key_outlined,
                        hint: 'XXXX-XXXX-XXXX-XXXX',
                        inputFormatters: [
                          TextInputFormatter.withFunction((old, nw) {
                            var t = nw.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
                            if (t.length > 16) t = t.substring(0, 16);
                            final buf = StringBuffer();
                            for (int i = 0; i < t.length; i++) {
                              if (i > 0 && i % 4 == 0) buf.write('-');
                              buf.write(t[i]);
                            }
                            final s = buf.toString();
                            return nw.copyWith(
                              text: s,
                              selection: TextSelection.collapsed(offset: s.length),
                            );
                          }),
                        ]),
                    const SizedBox(height: 12),
                    _field(_wbCtrl, 'WeighBridge ID', Icons.scale_outlined,
                        hint: 'WB-XXXXX',
                        type: TextInputType.text),
                    if (_lic.isDeviceBound) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Row(children: [
                          Icon(Icons.verified, size: 16, color: Colors.green.shade700),
                          const SizedBox(width: 8),
                          Flexible(child: Text(
                              'Device already registered — no activation code needed',
                              style: TextStyle(fontSize: 11, color: Colors.green.shade800))),
                        ]),
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      _field(_codeCtrl, 'Activation Code', Icons.lock_outline,
                          hint: 'XXXX-XXXX-XXXX-XXXX',
                          inputFormatters: [
                            TextInputFormatter.withFunction((old, nw) {
                              var t = nw.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
                              if (t.length > 16) t = t.substring(0, 16);
                              final buf = StringBuffer();
                              for (int i = 0; i < t.length; i++) {
                                if (i > 0 && i % 4 == 0) buf.write('-');
                                buf.write(t[i]);
                              }
                              final s = buf.toString();
                              return nw.copyWith(
                                text: s,
                                selection: TextSelection.collapsed(offset: s.length),
                              );
                            }),
                          ]),
                    ],
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                            color: cs.errorContainer,
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(_error,
                            style: TextStyle(color: cs.onErrorContainer, fontSize: 12)),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _loading ? null : _activate,
                      icon: _loading
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.verified_outlined),
                      label: Text(_loading ? 'Verifying…' : 'ACTIVATE LICENSE'),
                      style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                    const SizedBox(height: 8),
                    // Device ID — customer must share this with support to get activation code
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: _copyDeviceId,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Your Device ID (tap to copy)',
                              style: TextStyle(fontSize: 9, color: Colors.grey.shade600,
                                  letterSpacing: 0.5)),
                          const SizedBox(height: 2),
                          Row(children: [
                            Expanded(
                              child: Text(_lic.deviceId,
                                  style: const TextStyle(fontSize: 11,
                                      fontFamily: 'monospace', fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Icon(Icons.copy, size: 14, color: Colors.grey.shade500),
                          ]),
                          const SizedBox(height: 2),
                          Text('Share this with JBC support to receive your Activation Code',
                              style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ── Support ──────────────────────────────────────────────────────
            _SupportFooter(onCall: _callSupport, onEmail: _emailSupport),
            const SizedBox(height: 20),
          ]),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c, String label, IconData icon, {
    String hint = '',
    TextInputType type = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
  }) =>
      TextField(
        controller: c,
        keyboardType: type,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isNotEmpty ? hint : null,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
        ),
      );
}

// ── Widgets ────────────────────────────────────────────────────────────────────

class _TrialBanner extends StatelessWidget {
  final int daysLeft;
  final VoidCallback onUseTrial, onActivate;
  const _TrialBanner(
      {required this.daysLeft, required this.onUseTrial, required this.onActivate});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.timer_outlined, color: cs.primary),
            const SizedBox(width: 8),
            Text('FREE TRIAL ACTIVE',
                style: TextStyle(fontWeight: FontWeight.bold, color: cs.primary)),
          ]),
          const SizedBox(height: 8),
          Text('Days remaining: $daysLeft / $_kTrialDays',
              style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 4),
          Text('For license activation contact:\n'
              'Mobile: +91 9828023683\n'
              'Email: jbcorporation214@yahoo.com',
              style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer.withOpacity(0.8))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton(
              onPressed: onUseTrial,
              child: const Text('CONTINUE TRIAL'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(
              onPressed: onActivate,
              child: const Text('Activate License'),
            )),
          ]),
        ]),
      ),
    );
  }
}

class _ExpiredBanner extends StatelessWidget {
  final VoidCallback onActivate, onCall, onEmail;
  const _ExpiredBanner(
      {required this.onActivate, required this.onCall, required this.onEmail});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.error_outline, color: cs.error),
            const SizedBox(width: 8),
            Text('TRIAL EXPIRED',
                style: TextStyle(fontWeight: FontWeight.bold, color: cs.error)),
          ]),
          const SizedBox(height: 8),
          Text(
              'Your 3-day free trial has ended.\n'
              'Please activate your software license to continue.',
              style: TextStyle(fontSize: 12, color: cs.onErrorContainer)),
          const SizedBox(height: 8),
          Text('Contact Support:',
              style: TextStyle(fontWeight: FontWeight.bold, color: cs.onErrorContainer)),
          const SizedBox(height: 4),
          Text('Mobile: +91 9828023683\nEmail: jbcorporation214@yahoo.com',
              style: TextStyle(fontSize: 11, color: cs.onErrorContainer.withOpacity(0.9))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton(
              onPressed: onActivate,
              style: FilledButton.styleFrom(backgroundColor: cs.error),
              child: const Text('Activate License'),
            )),
            const SizedBox(width: 8),
            IconButton(onPressed: onCall,  icon: const Icon(Icons.call),  tooltip: 'Call Support'),
            IconButton(onPressed: onEmail, icon: const Icon(Icons.email), tooltip: 'Email Support'),
          ]),
        ]),
      ),
    );
  }
}

class _SupportFooter extends StatelessWidget {
  final VoidCallback onCall, onEmail;
  const _SupportFooter({required this.onCall, required this.onEmail});

  @override Widget build(BuildContext context) {
    return Column(children: [
      Text('Support', style: TextStyle(fontSize: 11,
          color: Colors.grey.shade500, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Wrap(alignment: WrapAlignment.center, children: [
        TextButton.icon(
          onPressed: onCall,
          icon: const Icon(Icons.call, size: 14),
          label: const Text('+91 9828023683', style: TextStyle(fontSize: 12)),
        ),
        TextButton.icon(
          onPressed: onEmail,
          icon: const Icon(Icons.email, size: 14),
          label: const Text('jbcorporation214@yahoo.com', style: TextStyle(fontSize: 11)),
        ),
      ]),
      Text('JBC Corporation', style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
    ]);
  }
}

