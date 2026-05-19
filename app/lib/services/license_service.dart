import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

// ── Encrypted storage keys (all written to Android Keystore / iOS Keychain) ──
const _kInstallDate   = 'gs_install_dt';
const _kLicenseKey    = 'gs_lic_key';
const _kWeighBridgeId = 'gs_wb_id';
const _kActivated     = 'gs_activated';
const _kBoundFp       = 'gs_bound_fp';    // device fingerprint at activation time
const _kActCode       = 'gs_act_code';    // activation code — stored after first use
const _kChecksum      = 'gs_checksum';    // HMAC-SHA256 of license bundle
const _kLicenseTs     = 'gs_lic_ts';      // ISO timestamp of activation
const _kApkSig        = 'gs_apk_sig';     // SHA-256 of APK signing certificate
const _kExpiry        = 'gs_expiry';

const _trialDays = 3;

// Salts embedded in compiled code — R8 encrypts these strings in release builds.
const _kHmacSalt    = r'GS$L@b3l#2024!JBC^Pr1nt3r*S3cur3Key';
const _kActCodeSalt = r'GSL@ct1v@t10n#T0k3n!2024^JBC*Pr1nt';
const _kActCodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 32 chars, no confusables

enum LicenseState { trial, trialExpired, activated }

class LicenseService {
  static const _apiUrl    = 'http://jbcweighingscale.com/admin_ws/api.php';
  static const _secCh     = MethodChannel('com.gslabel.gs_label_app/security');

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // ── In-memory state (populated by init()) ────────────────────────────────────
  String _fingerprint    = '';
  bool   _activated      = false;
  bool   _deviceBound    = false;   // true once activation code verified on this device
  String _storedActCode  = '';      // activation code persisted after first use
  String _licenseKey     = '';
  String _weighBridgeId  = '';
  String _installDate    = '';

  // ── Public API ────────────────────────────────────────────────────────────────
  bool   get isActivated       => _activated;
  /// True once the activation code has been verified on this device.
  /// Re-activation (expiry/server block) skips the activation code field.
  bool   get isDeviceBound     => _deviceBound;
  String get cachedLicenseKey    => _licenseKey;
  String get cachedWeighBridgeId => _weighBridgeId;
  String get deviceId            => _fingerprint;   // displayed in login UI

  int get trialDaysRemaining {
    if (_installDate.isEmpty) return _trialDays;
    final installed = DateTime.tryParse(_installDate);
    if (installed == null) return _trialDays;
    final elapsed = DateTime.now().difference(installed).inDays;
    return (_trialDays - elapsed).clamp(0, _trialDays);
  }

  bool get isTrialActive => trialDaysRemaining > 0;

  LicenseState get state {
    if (_activated)    return LicenseState.activated;
    if (isTrialActive) return LicenseState.trial;
    return LicenseState.trialExpired;
  }

  bool get canUseApp => _activated || isTrialActive;

  // ── Initialisation ────────────────────────────────────────────────────────────
  Future<void> init() async {
    // 1. Build multi-parameter device fingerprint
    _fingerprint = await _buildFingerprint();

    // 2. Ensure install date is persisted (encrypted)
    _installDate = await _storage.read(key: _kInstallDate) ?? '';
    if (_installDate.isEmpty) {
      _installDate = DateTime.now().toIso8601String();
      await _storage.write(key: _kInstallDate, value: _installDate);
    }

    // 3. Read persisted license state
    final storedAct = await _storage.read(key: _kActivated) ?? 'false';
    _licenseKey    = await _storage.read(key: _kLicenseKey)    ?? '';
    _weighBridgeId = await _storage.read(key: _kWeighBridgeId) ?? '';
    _storedActCode = await _storage.read(key: _kActCode)       ?? '';

    // 4. Device binding — fingerprint must match what was stored at activation
    final storedFp = await _storage.read(key: _kBoundFp) ?? '';

    // Mark device as bound if it previously completed activation code verification
    if (_storedActCode.isNotEmpty && storedFp == _fingerprint) {
      _deviceBound = true;
    }

    if (storedAct != 'true') { _activated = false; return; }
    if (storedFp.isNotEmpty && storedFp != _fingerprint) {
      await _revokeActivation(reason: 'device mismatch');
      return;
    }

    // 5. HMAC checksum — detects manual editing of encrypted storage
    final storedCs = await _storage.read(key: _kChecksum) ?? '';
    final storedTs = await _storage.read(key: _kLicenseTs) ?? '';
    if (_licenseKey.isNotEmpty && storedCs.isNotEmpty) {
      final expected = _computeHmac(_licenseKey, _weighBridgeId, _fingerprint, storedTs);
      if (storedCs != expected) {
        await _revokeActivation(reason: 'checksum mismatch');
        return;
      }
    }

    // 6. APK signature — detects repackaged / tampered APK
    final storedSig  = await _storage.read(key: _kApkSig) ?? '';
    final currentSig = await _getApkSignature();
    if (storedSig.isNotEmpty && currentSig.isNotEmpty && currentSig != storedSig) {
      await _revokeActivation(reason: 'APK signature mismatch');
      return;
    }

    _activated = true;
  }

  // ── Root detection ────────────────────────────────────────────────────────────
  /// Returns true if the device appears to be rooted.
  /// Call this after init(); result is advisory — app can warn without blocking.
  Future<bool> isDeviceRooted() async {
    if (!Platform.isAndroid) return false;
    const rootIndicators = [
      '/system/app/Superuser.apk',
      '/sbin/su', '/system/bin/su', '/system/xbin/su',
      '/data/local/xbin/su', '/data/local/bin/su',
      '/system/sd/xbin/su', '/data/local/su', '/su/bin/su',
    ];
    for (final path in rootIndicators) {
      if (File(path).existsSync()) return true;
    }
    return false;
  }

  // ── Activation code ──────────────────────────────────────────────────────────
  /// Generates the device-bound activation code for a given license + device.
  /// This same logic must be mirrored in the vendor's offline generator tool.
  static String generateActivationCode({
    required String licenseKey,
    required String weighBridgeId,
    required String deviceFingerprint,
  }) {
    final key  = utf8.encode(_kActCodeSalt);
    final data = utf8.encode(
        '${licenseKey.toUpperCase()}:${weighBridgeId.toUpperCase()}:$deviceFingerprint');
    final hash = Hmac(sha256, key).convert(data).bytes;
    final buf  = StringBuffer();
    for (int i = 0; i < 16; i++) {
      buf.write(_kActCodeChars[hash[i] % _kActCodeChars.length]);
    }
    final s = buf.toString();
    return '${s.substring(0,4)}-${s.substring(4,8)}-${s.substring(8,12)}-${s.substring(12,16)}';
  }

  bool _verifyActivationCode(String code, String licenseKey, String weighBridgeId) {
    final expected = generateActivationCode(
      licenseKey: licenseKey,
      weighBridgeId: weighBridgeId,
      deviceFingerprint: _fingerprint,
    );
    return code.toUpperCase().replaceAll('-', '') ==
           expected.toUpperCase().replaceAll('-', '');
  }

  // ── Activation ────────────────────────────────────────────────────────────────
  /// [activationCode] is required only on first activation for a new device.
  /// Once verified, it is stored encrypted and reused silently on re-activation.
  Future<String?> activate({
    required String licenseKey,
    required String weighBridgeId,
    String? activationCode,   // null = use stored code (re-activation on bound device)
  }) async {
    // ── Step 1: verify device-bound activation code (fully offline) ────────────
    final codeToCheck = activationCode ?? _storedActCode;
    if (codeToCheck.isEmpty) {
      return 'Activation code required. Contact support with your Device ID.';
    }
    if (!_verifyActivationCode(codeToCheck, licenseKey, weighBridgeId)) {
      return 'Invalid activation code for this device.\n'
             'Contact support with your Device ID to get the correct code.';
    }
    // ── Step 2: validate with server ──────────────────────────────────────────
    try {
      final resp = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'tag':           'checkLicense',
          'licenseKey':    licenseKey,
          'weighBridgeId': weighBridgeId,
          'mac_add':       _fingerprint,
        },
      ).timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) {
        return 'Server error (${resp.statusCode}) — try again';
      }

      final body = resp.body.trim();
      Map<String, dynamic>? json;
      try { json = jsonDecode(body) as Map<String, dynamic>; } catch (_) {}

      final isSuccess = _parseSuccess(json, body);

      if (isSuccess) {
        // Store all sensitive data encrypted in Keystore
        final ts  = DateTime.now().toIso8601String();
        final cs  = _computeHmac(licenseKey, weighBridgeId, _fingerprint, ts);
        final sig = await _getApkSignature();

        await _storage.write(key: _kActivated,    value: 'true');
        await _storage.write(key: _kLicenseKey,   value: licenseKey);
        await _storage.write(key: _kWeighBridgeId, value: weighBridgeId);
        await _storage.write(key: _kBoundFp,      value: _fingerprint);
        await _storage.write(key: _kActCode,      value: codeToCheck);
        await _storage.write(key: _kChecksum,     value: cs);
        await _storage.write(key: _kLicenseTs,    value: ts);
        if (sig.isNotEmpty) await _storage.write(key: _kApkSig, value: sig);

        final login  = json?['login'] as Map<String, dynamic>?;
        final expiry = (login?['expired_on'] ?? '').toString();
        if (expiry.isNotEmpty) await _storage.write(key: _kExpiry, value: expiry);

        _activated     = true;
        _deviceBound   = true;
        _storedActCode = codeToCheck;
        _licenseKey    = licenseKey;
        _weighBridgeId = weighBridgeId;
        return null; // success
      }

      return _parseError(json, body);
    } on SocketException {
      return 'No internet connection — check your network';
    } on HttpException {
      return 'Cannot reach the server — try again later';
    } catch (_) {
      return 'Connection timeout — try again';
    }
  }

  static const networkErrorPrefix = 'NET:';

  /// Called on every app open to re-verify with the server.
  /// Returns null if valid, 'NET:...' on connectivity failure, plain string on rejection.
  Future<String?> verifyOnline() async {
    if (_licenseKey.isEmpty || _weighBridgeId.isEmpty) return 'No license stored';

    try {
      final resp = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'tag':           'checkLicense',
          'licenseKey':    _licenseKey,
          'weighBridgeId': _weighBridgeId,
          'mac_add':       _fingerprint,
        },
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        return '${networkErrorPrefix}Server error (${resp.statusCode})';
      }

      final body = resp.body.trim();
      Map<String, dynamic>? json;
      try { json = jsonDecode(body) as Map<String, dynamic>; } catch (_) {}

      if (_parseSuccess(json, body)) {
        final login  = json?['login'] as Map<String, dynamic>?;
        final expiry = (login?['expired_on'] ?? '').toString();
        if (expiry.isNotEmpty) await _storage.write(key: _kExpiry, value: expiry);
        return null;
      }

      return _parseError(json, body) ?? 'License expired or invalid';
    } on SocketException {
      return '${networkErrorPrefix}No internet connection — cannot verify license';
    } catch (_) {
      return '${networkErrorPrefix}Cannot reach server — check your connection';
    }
  }

  Future<void> deactivate() async {
    _activated = false;
    await _storage.write(key: _kActivated, value: 'false');
    await _storage.delete(key: _kChecksum);
    await _storage.delete(key: _kLicenseTs);
    await _storage.delete(key: _kApkSig);
    // Keep: _kLicenseKey, _kWeighBridgeId  → form stays pre-filled
    // Keep: _kBoundFp, _kActCode            → device still bound, no code needed on re-activation
  }

  // ── Private helpers ───────────────────────────────────────────────────────────
  Future<void> _revokeActivation({required String reason}) async {
    _activated     = false;
    _licenseKey    = '';
    _weighBridgeId = '';
    await _storage.write(key: _kActivated, value: 'false');
    await _storage.delete(key: _kLicenseKey);
    await _storage.delete(key: _kWeighBridgeId);
    await _storage.delete(key: _kBoundFp);
    await _storage.delete(key: _kChecksum);
    await _storage.delete(key: _kLicenseTs);
    await _storage.delete(key: _kApkSig);
  }

  // HMAC-SHA256 of "key:wb:fingerprint:timestamp" — keyed with salt+fingerprint
  // so the checksum is device-specific and cannot be transplanted
  String _computeHmac(String key, String wb, String fp, String ts) {
    final hmacKey = utf8.encode(_kHmacSalt + fp);
    final data    = utf8.encode('$key:$wb:$fp:$ts');
    return Hmac(sha256, hmacKey).convert(data).toString();
  }

  // SHA-256 of android_id + brand + model + board + hardware
  static Future<String> _buildFingerprint() async {
    try {
      if (Platform.isAndroid) {
        final android = await DeviceInfoPlugin().androidInfo;
        final raw = '${android.id}|${android.brand}|${android.model}|'
                    '${android.board}|${android.hardware}';
        return sha256.convert(utf8.encode(raw)).toString();
      }
    } catch (_) {}
    // Fallback — only reached if device_info fails
    return sha256.convert(
      utf8.encode(DateTime.now().millisecondsSinceEpoch.toString()),
    ).toString();
  }

  // Native method channel → Android PackageManager signature
  static Future<String> _getApkSignature() async {
    try {
      final sig = await _secCh.invokeMethod<String>('getApkSignature');
      return sig ?? '';
    } catch (_) {
      return '';
    }
  }

  static bool _parseSuccess(Map<String, dynamic>? json, String body) {
    if (json != null) {
      final sv = json['success'];
      if (sv != null) {
        return sv == 1 || sv == true || sv.toString() == '1' ||
               sv.toString().toLowerCase() == 'true';
      }
      final ev = json['error'];
      if (ev != null) {
        return ev == 0 || ev == false || ev.toString() == '0';
      }
      final st = (json['status'] ?? json['result'] ?? json['state'] ?? '')
          .toString().toLowerCase();
      const ok = {'success','valid','active','activated','approved','ok','1','yes','true'};
      return ok.contains(st);
    }
    final b = body.toLowerCase();
    return b.contains('"success":1') || b.contains('"success": 1') ||
           b.contains('success')     || b.contains('valid') ||
           b.contains('active');
  }

  static String? _parseError(Map<String, dynamic>? json, String body) {
    if (json == null) return 'Server response: $body';
    final login    = json['login']    as Map<String, dynamic>?;
    final replyMsg = (json['replyMsg'] ?? '').toString();
    final msg = (login?['message'] ?? json['message'] ?? json['msg'] ??
                 json['error_message'] ?? replyMsg).toString().trim();
    if (msg.isNotEmpty && msg != 'null') return msg;
    return 'Server response: $body';
  }
}
