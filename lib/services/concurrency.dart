/// 并发控制：全局请求限流 + 有上限的任务池 + 429 退避重试。
///
/// - [requestLimiter]：所有联网请求（出题模型、DeepSeek OCR、Kimi）共用，同时在途的请求数不超过「并发数」设置。
///   只包住单次 HTTP 请求（不嵌套），所以不会互相等待而卡死。
/// - [runPool]：最多同时跑 N 个任务，结果按任务序号返回；N = 1 时与原来的顺序执行完全一样。
/// - [sendWithBackoff]：遇到 429（请求过多）时按指数退避 + 随机抖动重试，再交给原有的重试逻辑。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

/// 「并发数」的范围和默认值。DeepSeek 官方文档：deepseek-flash 每账号 2500 并发、deepseek-v4-pro 500 并发，超出返回 429。
const minConcurrency = 1;
const maxConcurrency = 2500;
const defaultConcurrency = 4;

/// 计数信号量：同时最多 [max] 个持有者，其余按先来后到排队。
class Limiter {
  int _max;
  int _active = 0;
  /// 出现过的最大同时持有数（测试用）。
  int peak = 0;
  final _waiters = Queue<Completer<void>>();
  Limiter(int max) : _max = max.clamp(minConcurrency, maxConcurrency);

  int get max => _max;
  set max(int v) {
    _max = v.clamp(minConcurrency, maxConcurrency);
    _drain();
  }

  int get active => _active;
  int get waiting => _waiters.length;

  void _take() {
    _active++;
    if (_active > peak) peak = _active;
  }

  Future<void> acquire() {
    if (_active < _max && _waiters.isEmpty) {
      _take();
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    _active--;
    _drain();
  }

  void _drain() {
    while (_active < _max && _waiters.isNotEmpty) {
      _take();
      _waiters.removeFirst().complete();
    }
  }

  Future<T> run<T>(Future<T> Function() f) async {
    await acquire();
    try {
      return await f();
    } finally {
      release();
    }
  }
}

/// 全局请求限流，大小由 AppState 按「并发数」设置。
final requestLimiter = Limiter(defaultConcurrency);

/// 最多同时运行 [concurrency] 个任务，结果按序号 0..count-1 排列。
/// 某个任务出错后不再开始新任务，等在途的任务结束后抛出第一个错误（与顺序执行时遇错即停一致）。
/// [onDone]：每完成一个任务回调一次（已完成数、总数）。
Future<List<T>> runPool<T>(int count, int concurrency, Future<T> Function(int i) task,
    {void Function(int done, int total)? onDone}) async {
  if (count <= 0) return <T>[];
  final results = List<T?>.filled(count, null);
  var next = 0, done = 0;
  Object? err;
  StackTrace? st;
  Future<void> worker() async {
    while (err == null && next < count) {
      final i = next++;
      try {
        results[i] = await task(i);
      } catch (e, s) {
        if (err == null) {
          err = e;
          st = s;
        }
        return;
      }
      done++;
      onDone?.call(done, count);
    }
  }

  final workers = min(concurrency.clamp(minConcurrency, maxConcurrency), count);
  await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  if (err != null) Error.throwWithStackTrace(err!, st!);
  return [for (final r in results) r as T];
}

/// 429 退避设置（测试可替换 [delay] 以免真的等待）。
class RateLimitBackoff {
  /// 遇到 429 时额外重试的次数（在原有的 3 次重试之外）。
  static int maxRetries = 5;
  static final _rng = Random();
  /// 第 [attempt] 次退避（0 起）：1 s、2 s、4 s…… 最多 30 s，再加 0–50% 的随机抖动。
  static Duration defaultDelay(int attempt) {
    final base = min(30000, 1000 * (1 << min(attempt, 15)));
    return Duration(milliseconds: base + _rng.nextInt(base ~/ 2 + 1));
  }

  static Duration Function(int attempt) delay = defaultDelay;
}

/// 通过全局限流发送一次请求；返回 429 时退避后重试（退避期间不占用并发名额）。
/// 重试用完仍是 429 时，把最后一次结果交回调用方，按原有逻辑处理。
Future<R> sendWithBackoff<R>(Future<R> Function() send, {required bool Function(R) rateLimited, Limiter? limiter}) async {
  final l = limiter ?? requestLimiter;
  for (var attempt = 0;; attempt++) {
    final r = await l.run(send);
    if (!rateLimited(r) || attempt >= RateLimitBackoff.maxRetries) return r;
    await Future.delayed(RateLimitBackoff.delay(attempt));
  }
}
