import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'settings.dart';

/// 桌面版的密钥存储：优先用系统钥匙串（Windows 凭据管理器 / macOS 钥匙串 / Linux Secret Service），
/// 用不了时自动改存到本机应用目录里的加密文件，应用不会因此打不开。
///
/// Linux 上如果没有可用的 Secret Service，`flutter_secure_storage` 会在原生层直接结束进程（Dart 里捕获不到），
/// 所以先用 D-Bus 探测；探测通过后第一次读写前还会记一个标记，万一仍然崩溃，下次启动就直接改用本机文件。
class DesktopSecretStore implements SecretStore {
  final SecretStore? _system;
  final FileSecretStore _file;
  bool _useFile;
  final SharedPreferences _prefs;
  bool _confirmed = false;

  DesktopSecretStore._(this._system, this._file, this._useFile, this._prefs);

  static const _modeKey = 'secret_store_mode'; // system / file
  static const _probeKey = 'secret_store_probing';

  /// 是否在用本机文件（设置里据此给一句说明）。
  static bool usingFile = false;

  static Future<DesktopSecretStore> create(SharedPreferences prefs, Directory dir) async {
    final file = FileSecretStore(dir);
    var useFile = prefs.getString(_modeKey) == 'file';
    if (!useFile && prefs.getBool(_probeKey) == true) {
      // 上次第一次访问钥匙串时进程被结束了：以后都用本机文件
      useFile = true;
    }
    if (!useFile && Platform.isLinux && !await linuxSecretServiceAvailable()) useFile = true;
    if (useFile) await prefs.setString(_modeKey, 'file');
    usingFile = useFile;
    const system = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
    return DesktopSecretStore._(useFile ? null : _Flutter(system), file, useFile, prefs);
  }

  /// 会话总线上有没有 org.freedesktop.secrets（GNOME 密钥环、KWallet 等）。
  static Future<bool> linuxSecretServiceAvailable() async {
    DBusClient? c;
    try {
      c = DBusClient.session();
      const name = 'org.freedesktop.secrets';
      final owned = await c.listNames().timeout(const Duration(seconds: 3));
      if (owned.contains(name)) return true;
      final act = await c.listActivatableNames().timeout(const Duration(seconds: 3));
      return act.contains(name);
    } catch (_) {
      return false;
    } finally {
      try {
        await c?.close();
      } catch (_) {}
    }
  }

  Future<T> _guard<T>(Future<T> Function(SecretStore s) f) async {
    if (_useFile || _system == null) return f(_file);
    if (!_confirmed) await _prefs.setBool(_probeKey, true);
    try {
      final r = await f(_system).timeout(const Duration(seconds: 8));
      if (!_confirmed) {
        _confirmed = true;
        await _prefs.setBool(_probeKey, false);
        await _prefs.setString(_modeKey, 'system');
      }
      return r;
    } catch (_) {
      // 钥匙串报错（未授权、被锁、超时…）：改用本机文件，不打断使用
      _useFile = true;
      usingFile = true;
      await _prefs.setBool(_probeKey, false);
      await _prefs.setString(_modeKey, 'file');
      return f(_file);
    }
  }

  @override
  Future<String?> read(String key) => _guard((s) => s.read(key));

  @override
  Future<void> write(String key, String value) => _guard((s) => s.write(key, value));
}

class _Flutter implements SecretStore {
  final FlutterSecureStorage s;
  _Flutter(this.s);
  @override
  Future<String?> read(String key) => s.read(key: key);
  @override
  Future<void> write(String key, String value) => s.write(key: key, value: value);
}

/// 本机加密文件：随机 32 字节密钥单独存一个只有自己能读的文件，内容用 HMAC-SHA256 计数器模式加密并校验。
/// 比不上系统钥匙串，但不会以明文出现在备份或磁盘上。
class FileSecretStore implements SecretStore {
  final Directory dir;
  FileSecretStore(this.dir);

  File get _keyFile => File(p.join(dir.path, 'secret.key'));
  File get _dataFile => File(p.join(dir.path, 'secrets.dat'));
  Map<String, String>? _cache;

  Future<Uint8List> _key() async {
    final f = _keyFile;
    if (await f.exists()) {
      final b = await f.readAsBytes();
      if (b.length == 32) return b;
    }
    await dir.create(recursive: true);
    final r = Random.secure();
    final k = Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
    await f.writeAsBytes(k, flush: true);
    await _private(f);
    return k;
  }

  static Future<void> _private(File f) async {
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {}
    }
  }

  static Uint8List _stream(Uint8List key, Uint8List nonce, int n) {
    final out = BytesBuilder();
    var i = 0;
    while (out.length < n) {
      final ctr = ByteData(4)..setUint32(0, i++);
      out.add(Hmac(sha256, key).convert([...nonce, ...ctr.buffer.asUint8List()]).bytes);
    }
    return Uint8List.fromList(out.toBytes().sublist(0, n));
  }

  static Uint8List encrypt(Uint8List key, Uint8List plain) {
    final r = Random.secure();
    final nonce = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    final ks = _stream(key, nonce, plain.length);
    final c = Uint8List.fromList([for (var i = 0; i < plain.length; i++) plain[i] ^ ks[i]]);
    final tag = Hmac(sha256, key).convert([...nonce, ...c]).bytes;
    return Uint8List.fromList([...nonce, ...tag, ...c]);
  }

  static Uint8List? decrypt(Uint8List key, Uint8List data) {
    if (data.length < 48) return null;
    final nonce = data.sublist(0, 16), tag = data.sublist(16, 48), c = data.sublist(48);
    final want = Hmac(sha256, key).convert([...nonce, ...c]).bytes;
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= want[i] ^ tag[i];
    }
    if (diff != 0) return null;
    final ks = _stream(key, nonce, c.length);
    return Uint8List.fromList([for (var i = 0; i < c.length; i++) c[i] ^ ks[i]]);
  }

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    final m = <String, String>{};
    try {
      if (await _dataFile.exists()) {
        final plain = decrypt(await _key(), await _dataFile.readAsBytes());
        if (plain != null) {
          (jsonDecode(utf8.decode(plain)) as Map).forEach((k, v) => m['$k'] = '$v');
        }
      }
    } catch (_) {}
    return _cache = m;
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) async {
    final m = await _load();
    m[key] = value;
    await dir.create(recursive: true);
    final f = _dataFile;
    await f.writeAsBytes(encrypt(await _key(), Uint8List.fromList(utf8.encode(jsonEncode(m)))), flush: true);
    await _private(f);
  }
}
