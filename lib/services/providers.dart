import 'dart:convert';

import 'package:http/http.dart' as http;

/// 拉取模型失败（可以改为手动添加模型名称）。
class FetchModelsException implements Exception {
  final String message;
  FetchModelsException(this.message);
  @override
  String toString() => message;
}

/// 内置服务商：一点就填好接口地址。Ollama 可以不填密钥。
class ProviderPreset {
  final String kind;
  final String name;
  final String baseUrl;
  final bool keyOptional;
  const ProviderPreset(this.kind, this.name, this.baseUrl, {this.keyOptional = false});

  static const all = [
    ProviderPreset('deepseek', 'DeepSeek', 'https://api.deepseek.com'),
    ProviderPreset('qwen', '通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
    ProviderPreset('zhipu', '智谱', 'https://open.bigmodel.cn/api/paas/v4'),
    ProviderPreset('kimi', 'Kimi', 'https://api.moonshot.cn/v1'),
    ProviderPreset('doubao', '豆包', 'https://ark.cn-beijing.volces.com/api/v3'),
    ProviderPreset('siliconflow', '硅基流动', 'https://api.siliconflow.cn/v1'),
    ProviderPreset('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1'),
    ProviderPreset('ollama', 'Ollama', 'http://127.0.0.1:11434/v1', keyOptional: true),
    ProviderPreset('custom', '自定义', '', keyOptional: true),
  ];

  static ProviderPreset of(String kind) => all.firstWhere((p) => p.kind == kind, orElse: () => all.last);
}

/// 用户添加的一个服务商（密钥另存在安全存储里）。
class LlmProvider {
  String id;
  String kind;
  String name;
  String baseUrl;
  List<String> models; // 拉取或手动添加的模型名
  /// 给模型起的显示名（模型 ID → 名称）。没起的就显示模型 ID。
  Map<String, String> modelNames;
  LlmProvider(
      {required this.id, required this.kind, required this.name, required this.baseUrl, List<String>? models, Map<String, String>? modelNames})
      : models = models ?? [],
        modelNames = modelNames ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'name': name,
        'baseUrl': baseUrl,
        'models': models,
        if (modelNames.isNotEmpty) 'modelNames': modelNames,
      };

  factory LlmProvider.fromJson(Map<String, dynamic> j) => LlmProvider(
        id: '${j['id']}',
        kind: '${j['kind'] ?? 'custom'}',
        name: '${j['name'] ?? ''}',
        baseUrl: '${j['baseUrl'] ?? ''}',
        models: [for (final m in (j['models'] as List?) ?? const []) '$m'],
        modelNames: {
          if (j['modelNames'] is Map)
            for (final e in (j['modelNames'] as Map).entries)
              if ('${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}'.trim(),
        },
      );

  /// 界面上显示的模型名：起了名字显示名字，否则显示模型 ID。
  String labelOf(String modelId) {
    final n = modelNames[modelId]?.trim() ?? '';
    return n.isEmpty ? modelId : n;
  }

  /// 设置（或清除，传空）显示名。
  void setModelName(String modelId, String name) {
    final n = name.trim();
    if (n.isEmpty || n == modelId) {
      modelNames.remove(modelId);
    } else {
      modelNames[modelId] = n;
    }
  }

  /// 删除一个模型，名字一起去掉。
  void removeModel(String modelId) {
    models.remove(modelId);
    modelNames.remove(modelId);
  }

  /// 用拉取结果更新列表。接口给了更好认的名字时填成昵称；已经起过的不覆盖。
  void applyFetched(List<CatalogModel> list) {
    models = [for (final e in list) e.id];
    modelNames.removeWhere((k, _) => !models.contains(k));
    for (final e in list) {
      final n = e.name?.trim() ?? '';
      if (n.isEmpty || modelNames.containsKey(e.id)) continue;
      setModelName(e.id, n);
    }
  }

  bool get isDeepSeek => kind == 'deepseek' || (Uri.tryParse(baseUrl)?.host == 'api.deepseek.com');
}

/// 功能用哪个模型。providerId / modelId 为空表示跟随出题模型（出题本身不能为空）。
class ModelChoice {
  final String? providerId;
  final String? modelId;
  const ModelChoice({this.providerId, this.modelId});
  bool get follow => providerId == null || providerId!.isEmpty || modelId == null || modelId!.isEmpty;
  Map<String, dynamic> toJson() => {if (providerId != null) 'providerId': providerId, if (modelId != null) 'modelId': modelId};
  factory ModelChoice.fromJson(Map<String, dynamic>? j) =>
      ModelChoice(providerId: j?['providerId'] as String?, modelId: j?['modelId'] as String?);
  static const followGenerate = ModelChoice();
}

enum LlmUse { generate, explain, study, web }

const llmUseNames = {
  LlmUse.generate: '出题',
  LlmUse.explain: 'AI 解释',
  LlmUse.study: 'AI 伴学',
  LlmUse.web: '联网',
};

/// 某一档思考强度：id 发给接口，label 显示给用户。
class ReasoningLevel {
  final String id;
  final String label;
  const ReasoningLevel(this.id, this.label);
}

/// 某个模型实际支持的思考档位。levels 就是界面上要画出来的全部选项；不支持时为 null（界面隐藏）。
class ReasoningSpec {
  final List<ReasoningLevel> levels;
  final String defaultId;
  /// 怎么把选中的档位写进请求：deepseek / qwen_effort / qwen_budget / glm / kimi / doubao / openai
  final String wire;
  const ReasoningSpec({required this.levels, required this.defaultId, required this.wire});
}

/// 按服务商文档，给「这个模型」列出真正能用的思考档位。不认识的模型返回 null。
class Reasoning {
  static const off = ReasoningLevel('none', '关闭');
  static const on = ReasoningLevel('enabled', '开启');
  static const low = ReasoningLevel('low', '较低');
  static const medium = ReasoningLevel('medium', '中等');
  static const high = ReasoningLevel('high', '较高');
  static const xhigh = ReasoningLevel('xhigh', '很高');
  static const max = ReasoningLevel('max', '最高');
  static const shortBudget = ReasoningLevel('budget_short', '较短');
  static const midBudget = ReasoningLevel('budget_mid', '中等');
  static const longBudget = ReasoningLevel('budget_long', '较长');

  static String _id(String model) => model.trim().toLowerCase().replaceAll('_', '-');

  /// [kind] 是服务商种类；OpenRouter / 硅基流动 / 自定义按模型名识别家族。
  static ReasoningSpec? of(String kind, String model) {
    final id = _id(model);
    if (id.isEmpty) return null;
    final family = _family(kind, id);
    return switch (family) {
      'deepseek' => const ReasoningSpec(
          // Chat Completions：reasoning_effort 实际档位是 none / low / high / max（其余会映射过去）
          // https://api-docs.deepseek.com/guides/thinking_mode/
          levels: [off, low, high, max],
          defaultId: 'high',
          wire: 'deepseek',
        ),
      'qwen4' => const ReasoningSpec(
          // qwen4-max：none 关闭；minimal/low→low；medium/high→high；xhigh/max→xhigh
          levels: [off, low, high, xhigh],
          defaultId: 'high',
          wire: 'qwen_effort',
        ),
      'qwen38' => const ReasoningSpec(
          // qwen3.8：low / medium / xhigh；none 映射为关闭思考
          levels: [off, low, medium, xhigh],
          defaultId: 'xhigh',
          wire: 'qwen_effort',
        ),
      'qwen3' => const ReasoningSpec(
          // Qwen3 / 3.5 / 3.6 / 3.7：enable_thinking + thinking_budget（档位用几个常用上限）
          levels: [off, shortBudget, midBudget, longBudget],
          defaultId: 'budget_mid',
          wire: 'qwen_budget',
        ),
      'glm53' => const ReasoningSpec(
          // GLM-5.3 不能关闭思考，只有 low / high / max
          levels: [low, high, max],
          defaultId: 'max',
          wire: 'glm',
        ),
      'glm52' => const ReasoningSpec(
          // GLM-5.2：none/minimal 关闭；low/medium→high；xhigh→max。界面只留真正不同的三档
          levels: [off, high, max],
          defaultId: 'max',
          wire: 'glm',
        ),
      'glm46' => const ReasoningSpec(
          // GLM-4.6 / 5 / 5.1：只有开关
          levels: [off, on],
          defaultId: 'enabled',
          wire: 'glm_toggle',
        ),
      'kimi_k3' => const ReasoningSpec(
          // K3 不能关闭思考，reasoning_effort：low / high / max
          levels: [low, high, max],
          defaultId: 'max',
          wire: 'kimi_effort',
        ),
      'kimi_k26' => const ReasoningSpec(
          levels: [off, on],
          defaultId: 'enabled',
          wire: 'kimi_toggle',
        ),
      'doubao21' => const ReasoningSpec(
          // Seed 2.1：minimal 关闭；xhigh/max→high。真正不同的是 关闭 / 较低 / 中等 / 较高
          levels: [ReasoningLevel('minimal', '关闭'), low, medium, high],
          defaultId: 'high',
          wire: 'doubao',
        ),
      'doubao20' => const ReasoningSpec(
          levels: [ReasoningLevel('minimal', '关闭'), low, medium, high],
          defaultId: 'medium',
          wire: 'doubao',
        ),
      'openai' => const ReasoningSpec(
          // GPT-5 / o 系列常见档：minimal / low / medium / high / xhigh
          levels: [ReasoningLevel('minimal', '关闭'), low, medium, high, xhigh],
          defaultId: 'medium',
          wire: 'openai',
        ),
      _ => null,
    };
  }

  static String? _family(String kind, String id) {
    if (kind == 'deepseek' || id.contains('deepseek-flash') || id.contains('deepseek-v4') || id.contains('deepseek-reasoner')) {
      return 'deepseek';
    }
    if (id.contains('qwen4') || id.contains('qwen-max') && id.contains('4')) return 'qwen4';
    if (id.contains('qwen3.8') || id.contains('qwen-3.8') || id.contains('qwen3-8')) return 'qwen38';
    if (id.contains('qwen3') || id.contains('qwen-3') || id.contains('qwen2.5') && id.contains('think')) return 'qwen3';
    if (id.contains('glm-5.3') || id.contains('glm-5-3') || id.contains('glm5.3')) return 'glm53';
    if (id.contains('glm-5.2') || id.contains('glm-5-2') || id.contains('glm5.2')) return 'glm52';
    if (id.contains('glm-4.6') || id.contains('glm-4.7') || id.contains('glm-4-6') || id.contains('glm-4-7') ||
        id.contains('glm-5.1') || id.contains('glm-5-1') || RegExp(r'glm-5($|[-.])').hasMatch(id)) {
      if (id.contains('glm-4.7') || id.contains('glm-4-7')) return null; // 强制思考，没有可选项
      return 'glm46';
    }
    if (id.contains('kimi-k3') || id.contains('kimi-k3.1') || id.contains('kimi/k3')) return 'kimi_k3';
    if (id.contains('kimi-k2.6') || id.contains('kimi-k2-6') || id.contains('kimi-k2.5')) return 'kimi_k26';
    if (id.contains('kimi-k2.7')) return null; // 强制思考
    if (id.contains('doubao-seed-2-1') || id.contains('doubao-seed-2.1') || id.contains('seed-evolving')) return 'doubao21';
    if (id.contains('doubao-seed-2-0') || id.contains('doubao-seed-2.0') || id.contains('seed-character')) return 'doubao20';
    if (id.startsWith('gpt-5') || RegExp(r'(^|[-./])o[1-4]($|[-./])').hasMatch(id)) return 'openai';
    if (kind == 'qwen' && (id.contains('qwen'))) return 'qwen3';
    if (kind == 'zhipu' && id.contains('glm')) return 'glm46';
    if (kind == 'kimi' && id.contains('kimi-k2') && !id.contains('k2.7')) return 'kimi_k26';
    if (kind == 'doubao' && id.contains('doubao')) return 'doubao21';
    return null;
  }

  /// 把用户选的档位写进请求体。深度搜索时 DeepSeek 必须开思考（可保留档位，但不能关掉）。
  static void apply(Map<String, Object?> body,
      {required String kind, required String model, String? level, bool deepSearch = false, bool normalSearch = false}) {
    final spec = of(kind, model);
    final chosen = level != null && spec != null && spec.levels.any((l) => l.id == level);
    final id = chosen ? level : spec?.defaultId;
    final deepWeb = deepSearch;
    final normalWeb = normalSearch;

    // 深度 / 普通联网仍按原来的定义控制思考；用户没选过档位时，不联网的请求保持原样（不额外加字段）
    if (spec?.wire == 'deepseek' || kind == 'deepseek' || body['tools'] != null) {
      if (normalWeb) {
        body['thinking'] = {'type': 'disabled'};
        body.remove('reasoning_effort');
        return;
      }
      if (deepWeb) {
        body['thinking'] = {'type': 'enabled'};
        if (chosen && id != 'none' && id != 'enabled') body['reasoning_effort'] = id;
        return;
      }
    }
    if (!chosen) return;
    switch (spec.wire) {
      case 'deepseek':
        if (id == 'none') {
          body['thinking'] = {'type': 'disabled'};
        } else {
          body['thinking'] = {'type': 'enabled'};
          body['reasoning_effort'] = id;
        }
      case 'qwen_effort':
        if (id == 'none') {
          body['enable_thinking'] = false;
        } else {
          body['enable_thinking'] = true;
          body['reasoning_effort'] = id;
        }
      case 'qwen_budget':
        if (id == 'none') {
          body['enable_thinking'] = false;
        } else {
          body['enable_thinking'] = true;
          body['thinking_budget'] = switch (id) {
            'budget_short' => 4096,
            'budget_long' => 32768,
            _ => 16384,
          };
        }
      case 'glm':
        if (id == 'none') {
          body['thinking'] = {'type': 'disabled'};
        } else {
          body['thinking'] = {'type': 'enabled'};
          body['reasoning_effort'] = id;
        }
      case 'glm_toggle':
        body['thinking'] = {'type': id == 'none' ? 'disabled' : 'enabled'};
      case 'kimi_effort':
        body['reasoning_effort'] = id;
      case 'kimi_toggle':
        body['thinking'] = {'type': id == 'none' ? 'disabled' : 'enabled'};
      case 'doubao':
        body['reasoning_effort'] = id;
      case 'openai':
        body['reasoning_effort'] = id;
    }
  }
}

/// 拉取到的一个模型：id 用来发请求，name 是接口给的更好认的名字（没有则为 null）。
class CatalogModel {
  final String id;
  final String? name;
  const CatalogModel(this.id, [this.name]);
}

/// 拉取模型列表、看图能力、上下文长度（都按模型名自动判断，不给用户填）。
class ModelCatalog {
  static Uri modelsUrl(String baseUrl) {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/chat/completions')) b = b.substring(0, b.length - '/chat/completions'.length);
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return Uri.parse('$b/models');
  }

  /// 接口给的显示名能不能当昵称：跟模型 ID 不同，而且看起来是给人看的。不凭 ID 自己编。
  static String? niceName(String id, String? raw) {
    final n = (raw ?? '').trim();
    if (n.isEmpty || n == id) return null;
    if (n.length > 80) return null;
    if (_looksLikeId(n) && n.toLowerCase() != id.toLowerCase()) return null;
    return n;
  }

  /// 像模型 ID 的字符串：没有空格和汉字，主要由小写字母、数字和 - / : . 组成。
  static bool _looksLikeId(String s) {
    if (RegExp(r'[\s\u4e00-\u9fff]').hasMatch(s)) return false;
    if (!RegExp(r'^[A-Za-z0-9._:/-]+$').hasMatch(s)) return false;
    return s.contains('-') || s.contains('/') || s.contains(':') || s.contains('.');
  }

  static List<CatalogModel> parse(String body) {
    final j = jsonDecode(body);
    final data = j is Map ? j['data'] ?? j['models'] : j;
    if (data is! List) return const [];
    final out = <CatalogModel>[];
    final seen = <String>{};
    for (final x in data) {
      late final String id;
      String? rawName;
      if (x is Map) {
        final idField = '${x['id'] ?? ''}'.trim();
        if (idField.isNotEmpty) {
          id = idField;
          rawName = '${x['display_name'] ?? x['displayName'] ?? x['name'] ?? ''}'.trim();
        } else {
          id = '${x['name'] ?? x['model'] ?? ''}'.trim();
          rawName = '${x['display_name'] ?? x['displayName'] ?? ''}'.trim();
        }
      } else {
        id = '$x'.trim();
      }
      if (id.isEmpty || !seen.add(id)) continue;
      out.add(CatalogModel(id, niceName(id, rawName)));
    }
    return out;
  }

  /// 拉取失败时抛 [FetchModelsException]，提示可以手动添加。
  static Future<List<CatalogModel>> fetch(String baseUrl, String apiKey, {http.Client? client}) async {
    if (baseUrl.trim().isEmpty) throw FetchModelsException('还没有填写接口地址');
    final c = client ?? http.Client();
    try {
      final r = await c
          .get(modelsUrl(baseUrl), headers: {
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          })
          .timeout(const Duration(seconds: 20));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw FetchModelsException('拉取失败（${r.statusCode}）。可以手动添加模型名称');
      }
      final list = parse(r.body);
      if (list.isEmpty) throw FetchModelsException('接口没有返回模型。可以手动添加模型名称');
      return list;
    } on FetchModelsException {
      rethrow;
    } catch (e) {
      throw FetchModelsException('拉取失败。可以手动添加模型名称');
    } finally {
      if (client == null) c.close();
    }
  }

  /// 看图能力按模型名判断（不提供编辑开关）。
  static bool canSeeImages(String model) {
    final id = model.trim().toLowerCase();
    if (id.isEmpty) return false;
    if (RegExp(r'deepseek-flash($|[-.])|deepseek-v4-flash|deepseek-vl|flash-vision').hasMatch(id)) return true;
    if (RegExp(r'(^|[-./_])(vl|vision|omni)($|[-./_])').hasMatch(id)) return true;
    if (id.contains('gpt-4o') || id.contains('gpt-4.1') || id.startsWith('gpt-5') && !id.contains('gpt-5-chat')) return true;
    if (id.contains('claude-3') || id.contains('claude-4') || id.contains('claude-sonnet') || id.contains('claude-haiku') || id.contains('claude-opus')) {
      return true;
    }
    if (id.contains('gemini') || id.contains('gemma-3') || id.contains('pixtral') || id.contains('llama-4')) return true;
    if (id.contains('qwen2-vl') || id.contains('qwen2.5-vl') || id.contains('qwen3-vl') || id.contains('qwen3.5') || id.contains('qwen-vl')) return true;
    if (id.contains('kimi-k2.5') || id.contains('kimi-vl') || id.contains('kimi-latest')) return true;
    if (id.contains('doubao') && (id.contains('vision') || id.contains('1.6') || id.contains('seed-2'))) return true;
    return false;
  }

  static int contextTokens(String model) {
    final id = model.trim().toLowerCase();
    if (id.contains('deepseek-flash') || id.contains('deepseek-v4') || id.contains('kimi-k3') || id.contains('glm-5.3')) return 1000000;
    return 128000;
  }

  /// 按接口地址识别内置服务商。
  static String kindOfUrl(String baseUrl) {
    final host = (Uri.tryParse(baseUrl.trim())?.host ?? '').toLowerCase();
    if (host == 'api.deepseek.com') return 'deepseek';
    if (host.contains('dashscope.aliyuncs.com')) return 'qwen';
    if (host.contains('open.bigmodel.cn') || host.contains('api.z.ai')) return 'zhipu';
    if (host.contains('moonshot.cn') || host.contains('kimi.com') || host.contains('kimi.ai')) return 'kimi';
    if (host.contains('volces.com') || host.contains('volcengineapi.com')) return 'doubao';
    if (host.contains('siliconflow.cn')) return 'siliconflow';
    if (host.contains('openrouter.ai')) return 'openrouter';
    if (host == '127.0.0.1' || host == 'localhost') return 'ollama';
    return 'custom';
  }
}
