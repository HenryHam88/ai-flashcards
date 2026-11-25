import 'dart:io';
import 'dart:typed_data';

import '../models.dart';

/// 读取资料原文件的统一入口。
///
/// 默认直接读本机文件；配置了云端存储后由 [CloudStorageService.installDocResolver] 接管：
/// 原文件已放到云端时会先自动下载回来，解析 / 按章重新解析等流程不需要关心文件在哪里。
class DocFiles {
  static Future<File> Function(PdfDoc doc)? resolver;

  static Future<File> file(PdfDoc doc) async => resolver == null ? File(doc.path) : await resolver!(doc);

  static Future<Uint8List> read(PdfDoc doc) async => (await file(doc)).readAsBytes();
}
