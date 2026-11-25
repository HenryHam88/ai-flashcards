import 'dart:convert';

import 'package:crypto/crypto.dart';

/// AWS Signature Version 4（S3 方言），纯 Dart 实现，只依赖 crypto。
///
/// 阿里云 OSS（S3 兼容 Endpoint）、腾讯云 COS、Cloudflare R2、MinIO 都接受这种签名，
/// 所以不需要引入任何厂商的原生 SDK（体积小、没有统计上报）。
/// 实现严格按 AWS 文档：规范请求 → 待签名字符串 → 派生密钥 → 签名。
class S3SigV4 {
  final String accessKey;
  final String secretKey;
  final String region;
  final String service;
  S3SigV4({required this.accessKey, required this.secretKey, required this.region, this.service = 's3'});

  /// 空请求体的 SHA-256。
  static const emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  static String hashHex(List<int> bytes) => sha256.convert(bytes).toString();

  static String _two(int v) => v.toString().padLeft(2, '0');
  static String amzDate(DateTime t) {
    final u = t.toUtc();
    return '${u.year}${_two(u.month)}${_two(u.day)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
  }

  /// RFC 3986 编码：只保留 A-Z a-z 0-9 - _ . ~；[keepSlash] 用于路径。
  static String uriEncode(String s, {bool keepSlash = false}) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      final unreserved = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || '-_.~'.contains(c);
      if (unreserved || (keepSlash && c == '/')) {
        out.write(c);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  /// 给请求签名，返回需要加到请求上的全部请求头（含 Authorization、x-amz-date、x-amz-content-sha256、host 以外的原有头）。
  ///
  /// [path] 为未编码的对象路径（以 / 开头），[query] 为未编码的查询参数。
  /// [payloadHash] 为请求体的 SHA-256（十六进制）；GET / HEAD / DELETE 用 [emptyHash]。
  Map<String, String> sign({
    required String method,
    required String host,
    required String path,
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    String payloadHash = emptyHash,
    DateTime? now,
  }) {
    final t = amzDate(now ?? DateTime.now());
    final day = t.substring(0, 8);
    final all = <String, String>{
      for (final e in headers.entries) e.key.toLowerCase(): e.value.trim().replaceAll(RegExp(r'\s+'), ' '),
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': t,
    };
    final names = all.keys.toList()..sort();
    final signedHeaders = names.join(';');
    final canonicalHeaders = names.map((n) => '$n:${all[n]}\n').join();
    final qKeys = query.keys.toList()..sort();
    final canonicalQuery = qKeys.map((k) => '${uriEncode(k)}=${uriEncode(query[k]!)}').join('&');
    final canonicalRequest = [
      method.toUpperCase(),
      uriEncode(path.isEmpty ? '/' : path, keepSlash: true),
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');
    final scope = '$day/$region/$service/aws4_request';
    final stringToSign = ['AWS4-HMAC-SHA256', t, scope, hashHex(utf8.encode(canonicalRequest))].join('\n');
    List<int> hmac(List<int> key, String msg) => Hmac(sha256, key).convert(utf8.encode(msg)).bytes;
    final kDate = hmac(utf8.encode('AWS4$secretKey'), day);
    final kRegion = hmac(kDate, region);
    final kService = hmac(kRegion, service);
    final kSigning = hmac(kService, 'aws4_request');
    final signature = Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).toString();
    return {
      for (final e in all.entries)
        if (e.key != 'host') e.key: e.value,
      'authorization': 'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }
}
