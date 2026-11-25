import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/font_coverage.dart';
import 'package:ai_flashcards/services/pdf_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bytes = File('assets/fonts/NotoSansSC-Regular-subset.ttf').readAsBytesSync();

  test('读出导出字体的字表：常用字、字母、标点都有，生僻字没有', () {
    final c = FontCoverage.parse(bytes)!;
    expect(c.length, greaterThan(3000));
    for (final ch in ['的', '概', '率', 'A', 'z', '0', '，', '。', '（']) {
      expect(c.has(ch.runes.first), isTrue, reason: ch);
    }
    expect(c.has('𠀀'.runes.first), isFalse);
  });

  test('缺字检查：去重、忽略空白和公式（公式转成图片）', () {
    final c = FontCoverage.parse(bytes)!;
    expect(c.missing(['条件概率 \$\\mathbb{P}(𠀀)\$ 与 \$\$𠀁\$\$', '换行\n\t空格']), isEmpty);
    expect(c.missing(['𠀀𠀀 正常 𠀁']), ['𠀀', '𠀁']);
    expect(FontCoverage.parse(Uint8List(10)), isNull);
  });

  test('错题集和笔记导出前收集全部文字', () {
    final svc = PdfExportService(bytes);
    final q = Question(id: 'q', projectId: 'p', type: QType.single, stem: '题干𠀀', options: ['A 选项', 'B 𠀁'], answer: 'A');
    expect(svc.missingGlyphs(PdfExportService.wrongTexts('错题', [ExportItem(question: q, lastAnswer: 'B')])), ['𠀀', '𠀁']);
    final n = StudyNote(id: 'n', projectId: 'p', title: '笔记', own: '我的理解𠀂');
    expect(svc.missingGlyphs(PdfExportService.noteTexts('笔记', [NoteExport(n)])), ['𠀂']);
  });
}
