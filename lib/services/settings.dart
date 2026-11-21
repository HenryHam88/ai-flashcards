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
