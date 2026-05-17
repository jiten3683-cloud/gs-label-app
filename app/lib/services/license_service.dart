import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _kInstallDate    = 'install_date';
const _kLicenseKey     = 'license_key';
const _kWeighBridgeId  = 'weighbridge_id';
const _kActivated      = 'license_activated';
const _kDeviceId       = 'device_id';
const _kBoundDeviceId  = 'bound_device_id'; // device locked at activation time
const _trialDays       = 3;

enum LicenseState { trial, trialExpired, activated }

class LicenseService {
  static const _apiUrl =
      'http://jbcweighingscale.com/admin_ws/api.php';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // Record installation date on first run
    if (_prefs!.getString(_kInstallDate) == null) {
      await _prefs!.setString(
          _kInstallDate, DateTime.now().toIso8601String());
    }
    // Generate/refresh device ID every init (always reflects current device)
    final currentId = await _buildDeviceId();
    await _prefs!.setString(_kDeviceId, currentId);

    // Device binding: if activated on a different device, wipe the activation
    if (_prefs!.getBool(_kActivated) == true) {
      final boundId = _prefs!.getString(_kBoundDeviceId) ?? '';
      if (boundId.isNotEmpty && boundId != currentId) {
        // App data was copied to a different device — revoke
        await _prefs!.setBool(_kActivated, false);
        await _prefs!.remove(_kLicenseKey);
        await _prefs!.remove(_kWeighBridgeId);
        await _prefs!.remove(_kBoundDeviceId);
      }
    }
  }

  // ── Trial ───────────────────────────────────────────────────────────────────
  int get trialDaysRemaining {
    final s = _prefs?.getString(_kInstallDate);
    if (s == null) return _trialDays;
    final installed = DateTime.tryParse(s);
    if (installed == null) return _trialDays;
    final elapsed = DateTime.now().difference(installed).inDays;
    return (_trialDays - elapsed).clamp(0, _trialDays);
  }

  bool get isTrialActive => trialDaysRemaining > 0;

  // ── License ─────────────────────────────────────────────────────────────────
  bool get isActivated => _prefs?.getBool(_kActivated) ?? false;

  String get cachedLicenseKey    => _prefs?.getString(_kLicenseKey)    ?? '';
  String get cachedWeighBridgeId => _prefs?.getString(_kWeighBridgeId) ?? '';
  String get deviceId            => _prefs?.getString(_kDeviceId)      ?? '';

  LicenseState get state {
    if (isActivated) return LicenseState.activated;
    if (isTrialActive) return LicenseState.trial;
    return LicenseState.trialExpired;
  }

  bool get canUseApp =>
      isActivated || isTrialActive;

  // ── API activation ──────────────────────────────────────────────────────────
  /// Returns null on success, or an error message string on failure.
  Future<String?> activate({
    required String licenseKey,
    required String weighBridgeId,
  }) async {
    final devId = deviceId;
    try {
      final resp = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'tag':           'checkLicense',
          'licenseKey':    licenseKey,
          'weighBridgeId': weighBridgeId,
          'mac_add':       devId,
        },
      ).timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) {
        return 'Server error (${resp.statusCode}) — try again';
      }

      final body = resp.body.trim();
      Map<String, dynamic>? json;
      try {
        json = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        // Plain-text response
      }

      // ── Success detection ─────────────────────────────────────────────────
      // Server returns: {"success":1,"error":0,"login":{...},"replyMsg":"..."}
      bool isSuccess = false;
      if (json != null) {
        final successVal = json['success'];
        final errorVal   = json['error'];
        // success=1 / error=0  (this server's format)
        if (successVal != null) {
          isSuccess = successVal == 1 || successVal == true ||
              successVal.toString() == '1' || successVal.toString().toLowerCase() == 'true';
        } else if (errorVal != null) {
          isSuccess = errorVal == 0 || errorVal == false ||
              errorVal.toString() == '0';
        } else {
          // Fallback: check common status fields
          final st = (json['status'] ?? json['result'] ?? json['state'] ?? '')
              .toString().toLowerCase();
          const ok = {'success', 'valid', 'active', 'activated', 'approved', 'ok', '1', 'yes', 'true'};
          isSuccess = ok.contains(st);
        }
      } else {
        final b = body.toLowerCase();
        isSuccess = b.contains('"success":1') || b.contains('"success": 1') ||
            b.contains('success') || b.contains('valid') || b.contains('active');
      }

      if (isSuccess) {
        final login  = json?['login'] as Map<String, dynamic>?;
        final expiry = login?['expired_on'] as String? ?? '';

        await _prefs!.setBool(_kActivated, true);
        await _prefs!.setString(_kLicenseKey,    licenseKey);
        await _prefs!.setString(_kWeighBridgeId, weighBridgeId);
        await _prefs!.setString(_kBoundDeviceId, devId); // lock to this device
        if (expiry.isNotEmpty) await _prefs!.setString('license_expiry', expiry);
        return null; // success
      }

      // ── Failure: extract server message ──────────────────────────────────────
      final login   = json?['login']    as Map<String, dynamic>?;
      final replyMsg = json?['replyMsg'] as String? ?? '';
      final serverMsg = (login?['message'] ?? json?['message'] ?? json?['msg'] ??
          json?['error_message'] ?? replyMsg).toString().trim();

      if (serverMsg.isNotEmpty && serverMsg != 'null') return serverMsg;
      return 'Server response: $body';
    } on SocketException {
      return 'No internet connection — check your network';
    } on HttpException {
      return 'Cannot reach the server — try again later';
    } catch (e) {
      return 'Connection timeout — try again';
    }
  }

  /// Prefix on returned string when the failure is a network/connectivity issue.
  /// Callers use this to show a Retry option instead of the activation form.
  static const networkErrorPrefix = 'NET:';

  /// Called on every app open (and 1-hour idle recheck) when locally activated.
  /// Returns null on server-confirmed valid.
  /// Returns 'NET:...' on network/connectivity failure.
  /// Returns plain string on license rejection (expired, wrong device, etc.).
  Future<String?> verifyOnline() async {
    final key   = cachedLicenseKey;
    final wb    = cachedWeighBridgeId;
    final devId = deviceId;
    if (key.isEmpty || wb.isEmpty) return 'No license stored';

    try {
      final resp = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'tag':           'checkLicense',
          'licenseKey':    key,
          'weighBridgeId': wb,
          'mac_add':       devId,
        },
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        return '${networkErrorPrefix}Server error (${resp.statusCode}) — try again';
      }

      final body = resp.body.trim();
      Map<String, dynamic>? json;
      try { json = jsonDecode(body) as Map<String, dynamic>; } catch (_) {}

      bool isValid = false;
      if (json != null) {
        final sv = json['success'];
        if (sv != null) {
          isValid = sv == 1 || sv == true || sv.toString() == '1';
        }
      }

      if (isValid) {
        final login  = json?['login'] as Map<String, dynamic>?;
        final expiry = login?['expired_on'] as String? ?? '';
        if (expiry.isNotEmpty) await _prefs!.setString('license_expiry', expiry);
        return null; // valid
      }

      // Server rejected — extract reason
      final login    = json?['login']    as Map<String, dynamic>?;
      final replyMsg = json?['replyMsg'] as String? ?? '';
      final msg = (login?['message'] ?? json?['message'] ?? json?['msg'] ??
          replyMsg).toString().trim();
      return msg.isNotEmpty && msg != 'null' ? msg : 'License expired or invalid';

    } on SocketException {
      return '${networkErrorPrefix}No internet connection — cannot verify license';
    } catch (_) {
      return '${networkErrorPrefix}Cannot reach server — check your connection';
    }
  }

  Future<void> deactivate() async {
    await _prefs?.setBool(_kActivated, false);
    await _prefs?.remove(_kBoundDeviceId);
    // Keep _kLicenseKey and _kWeighBridgeId so fields stay pre-filled on re-activation
  }

  // ── Device ID ───────────────────────────────────────────────────────────────
  static Future<String> _buildDeviceId() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        final id = android.id; // unique per device + signing key
        return id.isNotEmpty ? id : _fallback();
      }
    } catch (_) {}
    return _fallback();
  }

  static String _fallback() {
    // Deterministic from timestamp — only used if device info fails
    return DateTime.now().millisecondsSinceEpoch.toRadixString(16).toUpperCase();
  }
}
