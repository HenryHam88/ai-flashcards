import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'concurrency.dart';
import 'llm.dart';
import 'prompts.dart';
import 'providers.dart';

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

  bool _migrated = false;

  void _migrateSync() {
    if (_migrated) return;
    _migrated = true;
    if (prefs.getBool('llm_providers_v1') == true) return;
    final base = (prefs.getString('llm_base') ?? 'https://api.deepseek.com').trim();
    final model = (prefs.getString('llm_model') ?? 'deepseek-flash').trim();
    final kind = ModelCatalog.kindOfUrl(base);
    final gen = LlmProvider(
      id: 'p_generate',
      kind: kind,
      name: ProviderPreset.of(kind).name,
      baseUrl: base.isEmpty ? 'https://api.deepseek.com' : base,
      models: [if (model.isNotEmpty) model],
    );
    final list = <LlmProvider>[gen];
    LlmProvider addOrReuse(String baseUrl, String modelName, String prefix) {
      final b = baseUrl.trim().isEmpty ? gen.baseUrl : baseUrl.trim();
      final existing = list.cast<LlmProvider?>().firstWhere((p) => p!.baseUrl == b, orElse: () => null);
      if (existing != null) {
        if (modelName.isNotEmpty && !existing.models.contains(modelName)) existing.models.add(modelName);
        return existing;
      }
      final k = ModelCatalog.kindOfUrl(b);
      final p = LlmProvider(id: prefix, kind: k, name: ProviderPreset.of(k).name, baseUrl: b, models: [if (modelName.isNotEmpty) modelName]);
      list.add(p);
      return p;
    }

    final assigns = <String, ModelChoice>{
      LlmUse.generate.name: ModelChoice(providerId: gen.id, modelId: model.isEmpty ? 'deepseek-flash' : model),
    };
    final eb = (prefs.getString('explain_base') ?? '').trim();
    final em = (prefs.getString('explain_model') ?? '').trim();
    if (eb.isNotEmpty || em.isNotEmpty) {
      final p = addOrReuse(eb, em, 'p_explain');
      assigns[LlmUse.explain.name] = ModelChoice(providerId: p.id, modelId: em.isEmpty ? model : em);
    }
    final sb = (prefs.getString('study_base') ?? '').trim();
    final sm = (prefs.getString('study_model') ?? '').trim();
    if (sb.isNotEmpty || sm.isNotEmpty) {
      final p = addOrReuse(sb, sm, 'p_study');
      assigns[LlmUse.study.name] = ModelChoice(providerId: p.id, modelId: sm.isEmpty ? model : sm);
    }
    var webP = list.cast<LlmProvider?>().firstWhere((p) => p!.isDeepSeek, orElse: () => null);
    if (webP == null) {
      webP = LlmProvider(
          id: 'p_web',
          kind: 'deepseek',
          name: 'DeepSeek',
          baseUrl: Settings.webBaseUrl,
          models: const ['deepseek-flash', 'deepseek-v4-flash']);
      list.add(webP);
    }
    final wm = (prefs.getString('web_model') ?? 'deepseek-flash').trim();
    if (wm.isNotEmpty && !webP.models.contains(wm)) webP.models.add(wm);
    if (!webP.models.contains('deepseek-flash')) webP.models.insert(0, 'deepseek-flash');
    assigns[LlmUse.web.name] = ModelChoice(providerId: webP.id, modelId: wm.isEmpty ? 'deepseek-flash' : wm);
    prefs.setString('llm_providers', jsonEncode([for (final p in list) p.toJson()]));
    prefs.setString('llm_assignments', jsonEncode({for (final e in assigns.entries) e.key: e.value.toJson()}));
    prefs.setBool('llm_providers_v1', true);
  }

  /// 把旧的 llm_key / explain_key / study_key / web_key 抄到对应服务商。启动时调用一次即可。
  Future<void> ensureMigrated() async {
    _migrateSync();
    Future<void> copy(String providerId, String oldKey) async {
      final already = await secrets.read('provider_key_$providerId') ?? '';
      if (already.isNotEmpty) return;
      final v = await secrets.read(oldKey) ?? '';
      if (v.isNotEmpty) await secrets.write('provider_key_$providerId', v);
    }

    await copy(assignment(LlmUse.generate).providerId ?? 'p_generate', 'llm_key');
    final ex = assignment(LlmUse.explain);
    if (!ex.follow) await copy(ex.providerId!, 'explain_key');
    final sy = assignment(LlmUse.study);
    if (!sy.follow) await copy(sy.providerId!, 'study_key');
    final wb = assignment(LlmUse.web);
    if (!wb.follow) {
      final raw = await secrets.read('web_key') ?? '';
      final already = await secrets.read('provider_key_${wb.providerId}') ?? '';
      if (already.isEmpty && raw.isNotEmpty) await secrets.write('provider_key_${wb.providerId}', raw);
    }
  }

  String _newPid() => 'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  List<LlmProvider> get providers {
    _migrateSync();
    final raw = prefs.getString('llm_providers');
    if (raw == null || raw.isEmpty) return [];
    try {
      return [for (final x in jsonDecode(raw) as List) LlmProvider.fromJson((x as Map).cast<String, dynamic>())];
    } catch (_) {
      return [];
    }
  }

  set providers(List<LlmProvider> v) => prefs.setString('llm_providers', jsonEncode([for (final p in v) p.toJson()]));

  LlmProvider? providerById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  void upsertProvider(LlmProvider p) {
    final list = providers;
    final i = list.indexWhere((x) => x.id == p.id);
    if (i < 0) {
      list.add(p);
    } else {
      list[i] = p;
    }
    providers = list;
  }

  void removeProvider(String id) {
    providers = [for (final p in providers) if (p.id != id) p];
    for (final use in LlmUse.values) {
      final c = assignment(use);
      if (c.providerId != id) continue;
      if (use == LlmUse.generate) {
        final next = providers.isEmpty ? addPreset(ProviderPreset.of('deepseek')) : providers.first;
        setAssignment(use, ModelChoice(providerId: next.id, modelId: next.models.isEmpty ? 'deepseek-flash' : next.models.first));
      } else {
        setAssignment(use, const ModelChoice());
      }
    }
  }

  LlmProvider addPreset(ProviderPreset preset, {String? baseUrl}) {
    final p = LlmProvider(
      id: _newPid(),
      kind: preset.kind,
      name: preset.name,
      baseUrl: (baseUrl ?? preset.baseUrl).trim(),
      models: preset.kind == 'deepseek' ? ['deepseek-flash', 'deepseek-v4-pro'] : [],
    );
    upsertProvider(p);
    return p;
  }

  Map<String, ModelChoice> get _assignments {
    _migrateSync();
    final raw = prefs.getString('llm_assignments');
    if (raw == null || raw.isEmpty) return {};
    try {
      final j = jsonDecode(raw) as Map;
      return {for (final e in j.entries) e.key.toString(): ModelChoice.fromJson((e.value as Map).cast<String, dynamic>())};
    } catch (_) {
      return {};
    }
  }

  ModelChoice assignment(LlmUse use) {
    final c = _assignments[use.name];
    if (c != null) return c;
    if (use == LlmUse.generate) {
      final p = providers.isEmpty ? null : providers.first;
      return ModelChoice(providerId: p?.id, modelId: p?.models.isNotEmpty == true ? p!.models.first : (prefs.getString('llm_model') ?? 'deepseek-flash'));
    }
    return const ModelChoice();
  }

  void setAssignment(LlmUse use, ModelChoice c) {
    _migrateSync();
    final m = Map<String, ModelChoice>.of(_assignments);
    if (c.follow && use != LlmUse.generate) {
      m.remove(use.name);
    } else {
      m[use.name] = c;
    }
    prefs.setString('llm_assignments', jsonEncode({for (final e in m.entries) e.key: e.value.toJson()}));
    // 同步旧字段，已有测试和备份仍然有效
    if (use == LlmUse.generate && !c.follow) {
      final p = providerById(c.providerId);
      if (p != null) prefs.setString('llm_base', p.baseUrl);
      if ((c.modelId ?? '').isNotEmpty) prefs.setString('llm_model', c.modelId!);
    } else if (use == LlmUse.explain) {
      if (c.follow) {
        prefs.setString('explain_base', '');
        prefs.setString('explain_model', '');
      } else {
        final p = providerById(c.providerId);
        if (p != null) prefs.setString('explain_base', p.baseUrl);
        prefs.setString('explain_model', c.modelId ?? '');
      }
    } else if (use == LlmUse.study) {
      if (c.follow) {
        prefs.setString('study_base', '');
        prefs.setString('study_model', '');
      } else {
        final p = providerById(c.providerId);
        if (p != null) prefs.setString('study_base', p.baseUrl);
        prefs.setString('study_model', c.modelId ?? '');
      }
    } else if (use == LlmUse.web && !c.follow && (c.modelId ?? '').isNotEmpty) {
      prefs.setString('web_model', c.modelId!);
    }
  }

  String reasoningKey(LlmUse use, String providerId, String model) => '${use.name}|$providerId|$model';

  String? reasoningOf(LlmUse use, {String? providerId, String? model}) {
    final e = resolved(use, overrideProvider: providerId, overrideModel: model);
    if (e.providerId == null) return null;
    final raw = prefs.getString('llm_reasoning');
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map;
      return j[reasoningKey(use, e.providerId!, e.model)] as String?;
    } catch (_) {
      return null;
    }
  }

  void setReasoning(LlmUse use, String providerId, String model, String? level) {
    Map<String, dynamic> j = {};
    final raw = prefs.getString('llm_reasoning');
    if (raw != null && raw.isNotEmpty) {
      try {
        j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    final k = reasoningKey(use, providerId, model);
    if (level == null || level.isEmpty) {
      j.remove(k);
    } else {
      j[k] = level;
    }
    prefs.setString('llm_reasoning', jsonEncode(j));
  }

  int _contextOf(String model, int contextK) => contextK > 0 ? contextK * 1000 : ModelCatalog.contextTokens(model);

  /// 某个功能实际用的接口。解释 / 伴学没选时跟随出题；[overrideProvider] 用于伴学里换模型。
  LlmEndpoint resolved(LlmUse use, {String? overrideProvider, String? overrideModel}) {
    _migrateSync();
    var c = (overrideProvider != null && overrideProvider.isNotEmpty && overrideModel != null && overrideModel.isNotEmpty)
        ? ModelChoice(providerId: overrideProvider, modelId: overrideModel)
        : assignment(use);
    final custom = use != LlmUse.generate && !c.follow;
    if (c.follow && use != LlmUse.generate) c = assignment(LlmUse.generate);
    final p = providerById(c.providerId);
    final model = (c.modelId ?? '').isNotEmpty
        ? c.modelId!
        : (p != null && p.models.isNotEmpty ? p.models.first : (prefs.getString('llm_model') ?? 'deepseek-flash'));
    final base = p?.baseUrl ?? (prefs.getString('llm_base') ?? 'https://api.deepseek.com');
    final kind = p?.kind ?? ModelCatalog.kindOfUrl(base);
    final ctxK = use == LlmUse.explain
        ? explainContextK
        : use == LlmUse.study
            ? studyContextK
            : llmContextK;
    final reasonUse = custom || use == LlmUse.generate || use == LlmUse.web ? use : LlmUse.generate;
    final reasoning = p == null ? null : () {
      final raw = prefs.getString('llm_reasoning');
      if (raw == null || raw.isEmpty) return null;
      try {
        return (jsonDecode(raw) as Map)[reasoningKey(reasonUse, p.id, model)] as String?;
      } catch (_) {
        return null;
      }
    }();
    return LlmEndpoint(
      baseUrl: base,
      model: model,
      contextTokens: _contextOf(model, use == LlmUse.generate ? llmContextK : (custom ? ctxK : llmContextK)),
      custom: custom,
      kind: kind,
      providerId: p?.id,
      reasoning: reasoning,
    );
  }

  Future<String> providerKey(String id) async {
    final k = await secrets.read('provider_key_$id') ?? '';
    if (k.isNotEmpty) return k;
    if (id == assignment(LlmUse.generate).providerId) return await secrets.read('llm_key') ?? '';
    if (id == assignment(LlmUse.explain).providerId) {
      final v = await secrets.read('explain_key') ?? '';
      if (v.isNotEmpty) return v;
    }
    if (id == assignment(LlmUse.study).providerId) {
      final v = await secrets.read('study_key') ?? '';
      if (v.isNotEmpty) return v;
    }
    if (id == assignment(LlmUse.web).providerId) {
      final v = await secrets.read('web_key') ?? '';
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  Future<void> setProviderKey(String id, String v) async {
    await secrets.write('provider_key_$id', v.trim());
    if (id == assignment(LlmUse.generate).providerId) await secrets.write('llm_key', v.trim());
  }

  Future<String> keyFor(LlmEndpoint e) async {
    if (e.providerId != null) {
      final k = await providerKey(e.providerId!);
      if (k.isNotEmpty) return k;
    }
    return llmKey();
  }

  void _patchGenerate({String? baseUrl, String? model}) {
    _migrateSync();
    var c = assignment(LlmUse.generate);
    var p = providerById(c.providerId) ?? (providers.isNotEmpty ? providers.first : null);
    if (p == null) {
      p = addPreset(ProviderPreset.of(ModelCatalog.kindOfUrl(baseUrl ?? 'https://api.deepseek.com')), baseUrl: baseUrl);
    } else {
      if (baseUrl != null) {
        final leavingDeepSeek = p.isDeepSeek && ModelCatalog.kindOfUrl(baseUrl) != 'deepseek';
        final webC = assignment(LlmUse.web);
        if (leavingDeepSeek && webC.providerId == p.id) {
          final webP = addPreset(ProviderPreset.of('deepseek'));
          setAssignment(LlmUse.web, ModelChoice(providerId: webP.id, modelId: webC.modelId ?? 'deepseek-flash'));
        }
        p.baseUrl = baseUrl;
        p.kind = ModelCatalog.kindOfUrl(baseUrl);
        p.name = ProviderPreset.of(p.kind).name;
      }
      if (model != null && model.isNotEmpty && !p.models.contains(model)) p.models.add(model);
      upsertProvider(p);
    }
    setAssignment(LlmUse.generate, ModelChoice(providerId: p.id, modelId: model ?? c.modelId ?? (p.models.isEmpty ? 'deepseek-flash' : p.models.first)));
  }

  void _syncSlot(LlmUse use) {
    _migrateSync();
    final base = use == LlmUse.explain ? (prefs.getString('explain_base') ?? '') : (prefs.getString('study_base') ?? '');
    final model = use == LlmUse.explain ? (prefs.getString('explain_model') ?? '') : (prefs.getString('study_model') ?? '');
    if (base.trim().isEmpty && model.trim().isEmpty) {
      setAssignment(use, const ModelChoice());
      return;
    }
    final b = base.trim().isEmpty ? llmBaseUrl : base.trim();
    var p = providers.cast<LlmProvider?>().firstWhere((x) => x!.baseUrl == b, orElse: () => null);
    p ??= addPreset(ProviderPreset.of(ModelCatalog.kindOfUrl(b)), baseUrl: b);
    final m = model.trim().isEmpty ? llmModel : model.trim();
    if (m.isNotEmpty && !p.models.contains(m)) {
      p.models.add(m);
      upsertProvider(p);
    }
    setAssignment(use, ModelChoice(providerId: p.id, modelId: m));
  }

  // 出题模型（兼容旧字段；实际读服务商列表）
  String get llmBaseUrl {
    _migrateSync();
    return resolved(LlmUse.generate).baseUrl;
  }

  set llmBaseUrl(String v) {
    prefs.setString('llm_base', v.trim());
    _patchGenerate(baseUrl: v.trim());
  }

  String get llmModel {
    _migrateSync();
    return resolved(LlmUse.generate).model;
  }

  set llmModel(String v) {
    prefs.setString('llm_model', v.trim());
    _patchGenerate(model: v.trim());
  }

  Future<String> llmKey() async {
    _migrateSync();
    final id = assignment(LlmUse.generate).providerId;
    if (id != null) {
      final k = await secrets.read('provider_key_$id') ?? '';
      if (k.isNotEmpty) return k;
    }
    return await secrets.read('llm_key') ?? '';
  }

  Future<void> setLlmKey(String v) async {
    await secrets.write('llm_key', v.trim());
    _migrateSync();
    final id = assignment(LlmUse.generate).providerId;
    if (id != null) await secrets.write('provider_key_$id', v.trim());
  }

  // AI 联网（DeepSeek 服务端联网工具）。默认开启、默认深度搜索；出闪卡 / 出题永远不联网。
  bool get webSearch => prefs.getBool('web_search') ?? true;
  set webSearch(bool v) => prefs.setBool('web_search', v);
  WebMode get webMode => prefs.getString('web_mode') == 'normal' ? WebMode.normal : WebMode.deep;
  set webMode(WebMode v) => prefs.setString('web_mode', v == WebMode.normal ? 'normal' : 'deep');

  /// 上下文长度（千 token），0 = 自动（按模型名：DeepSeek 1M，其他 128K）。
  int get llmContextK => prefs.getInt('llm_context_k') ?? 0;
  set llmContextK(int v) => prefs.setInt('llm_context_k', v < 0 ? 0 : v);
  int get contextTokens => llmContextK > 0 ? llmContextK * 1000 : ModelCatalog.contextTokens(llmModel);

  // 联网模型：联网只能走 DeepSeek 的服务端工具。出题模型不是 deepseek-flash 时，
  // 先用这个模型（DeepSeek 接口）联网检索整理，再把结果交给出题模型回答。
  static const webBaseUrl = 'https://api.deepseek.com';
  String get webModel {
    _migrateSync();
    final c = assignment(LlmUse.web);
    if (!c.follow && (c.modelId ?? '').isNotEmpty) return c.modelId!;
    return prefs.getString('web_model') ?? 'deepseek-flash';
  }

  set webModel(String v) {
    prefs.setString('web_model', v.trim());
    _migrateSync();
    var p = providerById(assignment(LlmUse.web).providerId) ??
        providers.cast<LlmProvider?>().firstWhere((x) => x!.isDeepSeek, orElse: () => null);
    p ??= addPreset(ProviderPreset.of('deepseek'));
    if (v.trim().isNotEmpty && !p.models.contains(v.trim())) {
      p.models.add(v.trim());
      upsertProvider(p);
    }
    setAssignment(LlmUse.web, ModelChoice(providerId: p.id, modelId: v.trim().isEmpty ? 'deepseek-flash' : v.trim()));
  }

  Future<String> webKeyRaw() async => await secrets.read('web_key') ?? '';
  Future<void> setWebKey(String v) async {
    await secrets.write('web_key', v.trim());
    final id = assignment(LlmUse.web).providerId;
    if (id != null) await secrets.write('provider_key_$id', v.trim());
  }

  /// 联网模型用的密钥：单独填的优先；没填时用出题模型（接口是 DeepSeek 时）或 DeepSeek OCR 的密钥。
  Future<String> webKey() async {
    _migrateSync();
    final id = assignment(LlmUse.web).providerId;
    final webP = providerById(id);
    if (webP != null && webP.isDeepSeek) {
      final k = await providerKey(webP.id);
      if (k.isNotEmpty) return k;
    }
    final k = await webKeyRaw();
    if (k.isNotEmpty) return k;
    if (Uri.tryParse(llmBaseUrl.trim())?.host == 'api.deepseek.com') return llmKey();
    for (final p in providers.where((p) => p.isDeepSeek)) {
      final pk = await providerKey(p.id);
      if (pk.isNotEmpty) return pk;
    }
    if (Uri.tryParse(ocrBaseUrl.trim())?.host == 'api.deepseek.com') return await secrets.read('ocr_key') ?? '';
    return '';
  }

  /// 上次「保存到文件夹」选的位置（系统返回的文件地址），下次保存时从这个文件夹打开。只在本机，不进备份。
  String get lastSaveUri => prefs.getString('last_save_uri') ?? '';
  set lastSaveUri(String v) => prefs.setString('last_save_uri', v);

  // AI 解释 / AI 伴学模型：各项留空则沿用出题模型。
  String get explainBaseUrl => prefs.getString('explain_base') ?? '';
  set explainBaseUrl(String v) {
    prefs.setString('explain_base', v.trim());
    _syncSlot(LlmUse.explain);
  }

  String get explainModel => prefs.getString('explain_model') ?? '';
  set explainModel(String v) {
    prefs.setString('explain_model', v.trim());
    _syncSlot(LlmUse.explain);
  }

  int get explainContextK => prefs.getInt('explain_context_k') ?? 0;
  set explainContextK(int v) => prefs.setInt('explain_context_k', v < 0 ? 0 : v);
  Future<String> explainKeyRaw() async => await secrets.read('explain_key') ?? '';
  Future<void> setExplainKey(String v) => secrets.write('explain_key', v.trim());

  String get studyBaseUrl => prefs.getString('study_base') ?? '';
  set studyBaseUrl(String v) {
    prefs.setString('study_base', v.trim());
    _syncSlot(LlmUse.study);
  }

  String get studyModel => prefs.getString('study_model') ?? '';
  set studyModel(String v) {
    prefs.setString('study_model', v.trim());
    _syncSlot(LlmUse.study);
  }

  int get studyContextK => prefs.getInt('study_context_k') ?? 0;
  set studyContextK(int v) => prefs.setInt('study_context_k', v < 0 ? 0 : v);
  Future<String> studyKeyRaw() async => await secrets.read('study_key') ?? '';
  Future<void> setStudyKey(String v) => secrets.write('study_key', v.trim());

  /// 解析后的实际接口：没填的项用出题模型的值。
  LlmEndpoint get generate => resolved(LlmUse.generate);
  LlmEndpoint get explain => resolved(LlmUse.explain);
  LlmEndpoint get study => resolved(LlmUse.study);

  Future<String> explainKey() async {
    final e = explain;
    if (e.custom && e.providerId != null) {
      final k = await providerKey(e.providerId!);
      if (k.isNotEmpty) return k;
    }
    final k = await explainKeyRaw();
    return k.isNotEmpty ? k : llmKey();
  }

  Future<String> studyKey() async {
    final e = study;
    if (e.custom && e.providerId != null) {
      final k = await providerKey(e.providerId!);
      if (k.isNotEmpty) return k;
    }
    final k = await studyKeyRaw();
    return k.isNotEmpty ? k : llmKey();
  }

  bool webNativeOf(LlmEndpoint e) => LlmClient.webUnavailableReason(e.baseUrl, e.model) == null;
  bool webRelayOf(LlmEndpoint e) => !webNativeOf(e) && LlmClient.webModels.contains(webModel.trim());

  /// 出题模型自己就能联网（DeepSeek 接口 + deepseek-flash）。
  bool get webNative => webNativeOf(generate);

  /// 要借联网模型检索（出题模型不能直接联网，但联网模型可用）。
  bool get webRelay => webRelayOf(generate);

  /// 不能联网的原因；null = 可以联网（某个功能的模型可直接联网，或可借联网模型）。
  String? get webUnavailable {
    if (webNativeOf(generate) || webNativeOf(explain) || webNativeOf(study) || LlmClient.webModels.contains(webModel.trim())) return null;
    return '联网模型「${webModel.trim().isEmpty ? '未填写' : webModel.trim()}」不支持 DeepSeek 联网工具，请把联网模型改为 deepseek-flash';
  }

  /// 实际使用的联网方式：[chatOn] / [chatMode] 是单个对话的设置（null = 跟随全局）。
  WebMode web({bool? chatOn, WebMode? chatMode}) {
    if (webUnavailable != null) return WebMode.off;
    if (!(chatOn ?? webSearch)) return WebMode.off;
    return chatMode ?? webMode;
  }

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
  /// 每日新卡上限，0 = 不限。默认 20（v1.3.6 起新卡和复习分开计数）。
  int get dailyNewLimit => prefs.getInt('daily_new_limit') ?? 20;
  set dailyNewLimit(int v) => prefs.setInt('daily_new_limit', v < 0 ? 0 : v);

  /// 今天额外追加的新卡数（「今天再学 10 张」），按日期键记录，换日后自动失效。
  int newExtraFor(String day) {
    final v = prefs.getString('new_extra') ?? '';
    final i = v.indexOf('|');
    return i > 0 && v.substring(0, i) == day ? int.tryParse(v.substring(i + 1)) ?? 0 : 0;
  }

  void addNewExtra(String day, int n) => prefs.setString('new_extra', '$day|${newExtraFor(day) + n}');

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
  set autoCap(int v) => prefs.setInt('auto_cap', v.clamp(minAutoCap, maxAutoCap));
  static const minAutoCap = 5, maxAutoCap = 3000;

  /// 并发数：同时发出的联网请求上限（OCR 批次、知识点分析、出题批次共用），1–2500，默认 4。
  int get concurrency => (prefs.getInt('concurrency') ?? defaultConcurrency).clamp(minConcurrency, maxConcurrency);
  set concurrency(int v) {
    final n = v.clamp(minConcurrency, maxConcurrency);
    prefs.setInt('concurrency', n);
    requestLimiter.max = n;
  }

  // ---------- 云端存储（省手机空间） ----------
  // 只存连接信息；AccessKey 存在系统安全存储里，并且不进入任何备份（见 [cloudKeyId] / [cloudSecret]）。
  String get cloudProvider => prefs.getString('cloud_provider') ?? 'aliyun'; // aliyun / tencent / s3
  set cloudProvider(String v) => prefs.setString('cloud_provider', v);
  String get cloudRegion => prefs.getString('cloud_region') ?? '';
  set cloudRegion(String v) => prefs.setString('cloud_region', v.trim());
  String get cloudBucket => prefs.getString('cloud_bucket') ?? '';
  set cloudBucket(String v) => prefs.setString('cloud_bucket', v.trim());
  /// 自定义 S3 兼容服务的地址（阿里云 / 腾讯云按地域自动生成，留空即可）。
  String get cloudEndpoint => prefs.getString('cloud_endpoint') ?? '';
  set cloudEndpoint(String v) => prefs.setString('cloud_endpoint', v.trim());
  /// 对象路径前缀，默认 ai-flashcards/。
  String get cloudPrefix => prefs.getString('cloud_prefix') ?? 'ai-flashcards/';
  set cloudPrefix(String v) => prefs.setString('cloud_prefix', v.trim());
  /// 从云端下载回来的文件在本机最多占多少 MB，超过后自动删除最久没用的（云端仍保留）。
  int get cloudCacheMb => prefs.getInt('cloud_cache_mb') ?? 300;
  set cloudCacheMb(int v) => prefs.setInt('cloud_cache_mb', v.clamp(50, 5000));
  Future<String> cloudKeyId() async => await secrets.read('cloud_ak') ?? '';
  Future<void> setCloudKeyId(String v) => secrets.write('cloud_ak', v.trim());
  Future<String> cloudSecret() async => await secrets.read('cloud_sk') ?? '';
  Future<void> setCloudSecret(String v) => secrets.write('cloud_sk', v.trim());

  /// 云端存储是否填写完整（没买 / 没填时整个功能自动隐藏，不影响使用）。
  Future<bool> cloudConfigured() async =>
      cloudBucket.isNotEmpty &&
      (cloudRegion.isNotEmpty || cloudEndpoint.isNotEmpty) &&
      (await cloudKeyId()).isNotEmpty &&
      (await cloudSecret()).isNotEmpty;

  // ---------- 首次启动 ----------
  bool get onboarded => prefs.getBool('onboarded') ?? false;
  set onboarded(bool v) => prefs.setBool('onboarded', v);

  /// 不含任何密钥的设置项，用于备份。
  static const backupKeys = [
    'llm_base', 'llm_model', 'llm_context_k', 'explain_base', 'explain_model', 'explain_context_k', 'study_base', 'study_model', 'study_context_k', 'web_search', 'web_mode', 'web_model', 'ocr_provider', 'ocr_modes', 'ocr_base', 'ocr_batch', 'kimi_base', 'gen_templates',
    'daily_new_limit', 'daily_review_limit', 'desired_retention', 'day_start_hour', 'theme_mode', 'text_scale',
    'math_scale', 'reduce_motion', 'haptics', 'reminder_on', 'reminder_minutes', 'auto_backup', 'review_before_add',
    'auto_cap', 'concurrency', 'llm_providers', 'llm_assignments', 'llm_reasoning', 'llm_providers_v1',
  ];
  /// 可以随备份导出的密钥（用户勾选「包含 API 密钥」时）。
  /// 云端存储的 AccessKey（cloud_ak / cloud_sk）故意不在这里：备份文件本身可能被上传到云端，绝不能带着钥匙。
  static const secretKeys = ['llm_key', 'ocr_key', 'kimi_key', 'web_key', 'explain_key', 'study_key'];

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
    requestLimiter.max = concurrency;
  }

  Future<Map<String, String>> exportSecrets() async {
    final keys = [...secretKeys, for (final p in providers) 'provider_key_${p.id}'];
    final out = <String, String>{};
    for (final k in keys) {
      final v = await secrets.read(k) ?? '';
      if (v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  Future<void> importSecrets(Map<String, dynamic> m) async {
    for (final e in m.entries) {
      if (!(secretKeys.contains(e.key) || e.key.startsWith('provider_key_'))) continue;
      final v = e.value;
      if (v is String && v.isNotEmpty) await secrets.write(e.key, v);
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

/// 实际调用时用的模型接口。
class LlmEndpoint {
  final String baseUrl;
  final String model;
  final int contextTokens;
  final bool custom; // 这项有单独填写的接口、模型或上下文
  final String kind;
  final String? providerId;
  final String? reasoning;
  const LlmEndpoint({
    required this.baseUrl,
    required this.model,
    required this.contextTokens,
    this.custom = true,
    this.kind = 'custom',
    this.providerId,
    this.reasoning,
  });
}
