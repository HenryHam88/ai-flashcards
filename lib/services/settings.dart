import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'prompts.dart';

/// 密钥存储抽象（正式环境用 flutter_secure_storage，测试用内存）。
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureSecretStore implements SecretStore {
  final _s = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> m = {};
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
}

enum OcrProvider { deepseek, kimi, local }

const ocrProviderNames = {
  OcrProvider.deepseek: 'DeepSeek OCR（推荐）',
  OcrProvider.kimi: 'Kimi 文件解析',
  OcrProvider.local: '本地提取文字层（免费）',
};

/// 全部设置：普通项存 SharedPreferences，密钥存安全存储。
class Settings {
  final SharedPreferences prefs;
  final SecretStore secrets;
  Settings(this.prefs, this.secrets);

  // 出题模型
  String get llmBaseUrl => prefs.getString('llm_base') ?? 'https://api.deepseek.com';
  set llmBaseUrl(String v) => prefs.setString('llm_base', v.trim());
  String get llmModel => prefs.getString('llm_model') ?? 'deepseek-flash';
  set llmModel(String v) => prefs.setString('llm_model', v.trim());
  Future<String> llmKey() async => await secrets.read('llm_key') ?? '';
  Future<void> setLlmKey(String v) => secrets.write('llm_key', v.trim());

  // PDF 解析
  OcrProvider get ocrProvider =>
      OcrProvider.values.firstWhere((e) => e.name == prefs.getString('ocr_provider'), orElse: () => OcrProvider.deepseek);
  set ocrProvider(OcrProvider v) => prefs.setString('ocr_provider', v.name);
  static const ocrText = 'text_recognition';
  static const ocrRich = 'rich_layout_recognition';

  /// DeepSeek OCR 模式，可同时选两个（混合模式）。兼容旧版单值设置 ocr_mode。
  List<String> get ocrModes {
    final l = prefs.getStringList('ocr_modes');
    if (l != null && l.isNotEmpty) return l;
    return [prefs.getString('ocr_mode') ?? ocrText];
  }

  set ocrModes(List<String> v) {
    final clean = [ocrText, ocrRich].where(v.contains).toList();
    prefs.setStringList('ocr_modes', clean.isEmpty ? [ocrText] : clean);
    prefs.remove('ocr_mode');
  }

  /// 各解析方式支持的格式（依据 DeepSeek OCR 与 Kimi 文件接口的官方文档）。
  static const providerFormats = {
    OcrProvider.deepseek: 'PDF、Word（.docx / .doc）',
    OcrProvider.kimi: 'PDF、Word（.docx / .doc）',
    OcrProvider.local: '仅 PDF',
  };
  static bool supportsWord(OcrProvider p) => p != OcrProvider.local;

  bool get ocrMixed => ocrModes.length > 1;
  String get ocrBaseUrl => prefs.getString('ocr_base') ?? 'https://api.deepseek.com';
  set ocrBaseUrl(String v) => prefs.setString('ocr_base', v.trim());
  int get ocrBatchPages => prefs.getInt('ocr_batch') ?? 30;
  set ocrBatchPages(int v) => prefs.setInt('ocr_batch', v);

  /// OCR 密钥：留空则使用出题模型的 DeepSeek 密钥。
  Future<String> ocrKey() async {
    final k = await secrets.read('ocr_key') ?? '';
    return k.isNotEmpty ? k : await llmKey();
  }

  Future<String> ocrKeyRaw() async => await secrets.read('ocr_key') ?? '';
  Future<void> setOcrKey(String v) => secrets.write('ocr_key', v.trim());

  String get kimiBaseUrl => prefs.getString('kimi_base') ?? 'https://api.moonshot.cn/v1';
  set kimiBaseUrl(String v) => prefs.setString('kimi_base', v.trim());
  Future<String> kimiKey() async => await secrets.read('kimi_key') ?? '';
  Future<void> setKimiKey(String v) => secrets.write('kimi_key', v.trim());

  // ---------- 学习设置（默认值与旧版行为完全一致） ----------
  /// 每日新卡上限，0 = 不限（旧版行为）。
  int get dailyNewLimit => prefs.getInt('daily_new_limit') ?? 0;
  set dailyNewLimit(int v) => prefs.setInt('daily_new_limit', v < 0 ? 0 : v);

  /// 每日复习上限，0 = 不限（旧版行为）。
  int get dailyReviewLimit => prefs.getInt('daily_review_limit') ?? 0;
  set dailyReviewLimit(int v) => prefs.setInt('daily_review_limit', v < 0 ? 0 : v);

  /// FSRS 目标记忆率，默认 0.90（旧版固定值）。
  double get desiredRetention => prefs.getDouble('desired_retention') ?? 0.9;
  set desiredRetention(double v) => prefs.setDouble('desired_retention', v.clamp(0.70, 0.97));

  /// 每日开始时间（小时），默认 0 点。用于计算「今天」已学的新卡 / 复习数。
  int get dayStartHour => prefs.getInt('day_start_hour') ?? 0;
  set dayStartHour(int v) => prefs.setInt('day_start_hour', v.clamp(0, 6));

  // ---------- 外观 ----------
  /// light / dark / system。默认浅色（与旧版一致）。
  String get themeMode => prefs.getString('theme_mode') ?? 'light';
  set themeMode(String v) => prefs.setString('theme_mode', v);
  double get textScale => prefs.getDouble('text_scale') ?? 1.0;
  set textScale(double v) => prefs.setDouble('text_scale', v);
  double get mathScale => prefs.getDouble('math_scale') ?? 1.0;
  set mathScale(double v) => prefs.setDouble('math_scale', v);
  bool get haptics => prefs.getBool('haptics') ?? true;
  set haptics(bool v) => prefs.setBool('haptics', v);
  bool get reduceMotion => prefs.getBool('reduce_motion') ?? false;
  set reduceMotion(bool v) => prefs.setBool('reduce_motion', v);

  // ---------- 提醒 ----------
  bool get reminderOn => prefs.getBool('reminder_on') ?? false;
  set reminderOn(bool v) => prefs.setBool('reminder_on', v);
  int get reminderMinutes => prefs.getInt('reminder_minutes') ?? 20 * 60; // 默认 20:00
  set reminderMinutes(int v) => prefs.setInt('reminder_minutes', v);

  // ---------- 数据 ----------
  bool get autoBackup => prefs.getBool('auto_backup') ?? false;
  set autoBackup(bool v) => prefs.setBool('auto_backup', v);
  DateTime? get lastAutoBackup => DateTime.tryParse(prefs.getString('last_auto_backup') ?? '');
  set lastAutoBackup(DateTime? v) => prefs.setString('last_auto_backup', v?.toIso8601String() ?? '');

  // ---------- 质量控制 ----------
  /// 生成后先放进「待审核」，确认后才加入复习。默认关闭（与旧版一致：直接加入）。
  bool get reviewBeforeAdd => prefs.getBool('review_before_add') ?? false;
  set reviewBeforeAdd(bool v) => prefs.setBool('review_before_add', v);

  /// 「自动（按知识点）」数量的单次上限（闪卡 + 题目），防止数量和费用过高。
  int get autoCap => prefs.getInt('auto_cap') ?? 40;
  set autoCap(int v) => prefs.setInt('auto_cap', v);

  // ---------- 首次启动 ----------
  bool get onboarded => prefs.getBool('onboarded') ?? false;
  set onboarded(bool v) => prefs.setBool('onboarded', v);

  /// 不含任何密钥的设置项，用于备份。
  static const backupKeys = [
    'llm_base', 'llm_model', 'ocr_provider', 'ocr_modes', 'ocr_base', 'ocr_batch', 'kimi_base', 'gen_templates',
    'daily_new_limit', 'daily_review_limit', 'desired_retention', 'day_start_hour', 'theme_mode', 'text_scale',
    'math_scale', 'reduce_motion', 'haptics', 'reminder_on', 'reminder_minutes', 'auto_backup', 'review_before_add',
    'auto_cap',
  ];
  static const secretKeys = ['llm_key', 'ocr_key', 'kimi_key'];

  Map<String, dynamic> exportPrefs() {
    final out = <String, dynamic>{};
    for (final k in prefs.getKeys()) {
      if (backupKeys.contains(k) || k.startsWith('prompt_')) out[k] = prefs.get(k);
    }
    return out;
  }

  Future<void> importPrefs(Map<String, dynamic> m) async {
    for (final e in m.entries) {
      final v = e.value;
      if (!(backupKeys.contains(e.key) || e.key.startsWith('prompt_'))) continue;
      if (v is bool) {
        await prefs.setBool(e.key, v);
      } else if (v is int) {
        await prefs.setInt(e.key, v);
      } else if (v is double) {
        await prefs.setDouble(e.key, v);
      } else if (v is String) {
        await prefs.setString(e.key, v);
      } else if (v is List) {
        await prefs.setStringList(e.key, v.map((x) => '$x').toList());
      }
    }
  }

  Future<Map<String, String>> exportSecrets() async => {
        for (final k in secretKeys)
          if ((await secrets.read(k) ?? '').isNotEmpty) k: (await secrets.read(k))!,
      };

  Future<void> importSecrets(Map<String, dynamic> m) async {
    for (final k in secretKeys) {
      final v = m[k];
      if (v is String && v.isNotEmpty) await secrets.write(k, v);
    }
  }

  // 提示词模板（高级）
  String prompt(String name) => prefs.getString('prompt_$name') ?? Prompts.defaults[name]!;
  void setPrompt(String name, String v) => prefs.setString('prompt_$name', v);
  void resetPrompt(String name) => prefs.remove('prompt_$name');

  // 生成选项模板
  Map<String, Map<String, dynamic>> get genTemplates {
    final raw = prefs.getString('gen_templates');
    if (raw == null) {
      return {
        '期末冲刺': {
          'cardCount': 15,
          'questionCount': 20,
          'types': ['单选', '多选', '计算', '简答'],
          'difficulty': '拔高',
          'focus': ['计算应用', '易错点'],
          'custom': '',
        },
        '概念速记': {
          'cardCount': 30,
          'questionCount': 5,
          'types': ['判断', '填空'],
          'difficulty': '基础',
          'focus': ['概念定义', '公式定理'],
          'custom': '闪卡背面附一个简短例子',
        },
      };
    }
    return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), (v as Map).cast<String, dynamic>()));
  }

  set genTemplates(Map<String, Map<String, dynamic>> v) => prefs.setString('gen_templates', jsonEncode(v));

  // 复习会话（进度持久化，防止回到第一张）
  Map<String, dynamic>? get reviewSession {
    final raw = prefs.getString('review_session');
    return raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  set reviewSession(Map<String, dynamic>? v) =>
      v == null ? prefs.remove('review_session') : prefs.setString('review_session', jsonEncode(v));

  Map<String, dynamic>? quizSession(String key) {
    final raw = prefs.getString('quiz_$key');
    return raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  void setQuizSession(String key, Map<String, dynamic>? v) =>
      v == null ? prefs.remove('quiz_$key') : prefs.setString('quiz_$key', jsonEncode(v));
}
