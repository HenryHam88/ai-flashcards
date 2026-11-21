import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 最底层的存储接口：按「集合」存 JSON 文档。
/// 以后加 WebDAV 同步时，只需新增一个实现（或在此之上做增量导出），上层无需改动。
abstract class DocStore {
  Future<void> put(String collection, String id, String projectId, Map<String, dynamic> doc);
  Future<void> putAll(String collection, List<(String id, String projectId, Map<String, dynamic> doc)> docs);
  Future<Map<String, dynamic>?> get(String collection, String id);
  Future<List<Map<String, dynamic>>> list(String collection, {String? projectId});
  Future<void> delete(String collection, String id);
  Future<void> deleteWhere(String collection, {required String projectId, String? field, String? equals});
}

class MemoryDocStore implements DocStore {
  final Map<String, Map<String, (String, Map<String, dynamic>)>> _data = {};
  Map<String, (String, Map<String, dynamic>)> _c(String c) => _data.putIfAbsent(c, () => {});

  @override
  Future<void> put(String collection, String id, String projectId, Map<String, dynamic> doc) async {
    _c(collection)[id] = (projectId, jsonDecode(jsonEncode(doc)) as Map<String, dynamic>);
  }

  @override
  Future<void> putAll(String collection, List<(String, String, Map<String, dynamic>)> docs) async {
    for (final d in docs) {
      await put(collection, d.$1, d.$2, d.$3);
    }
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async => _c(collection)[id]?.$2;

  @override
  Future<List<Map<String, dynamic>>> list(String collection, {String? projectId}) async => _c(collection)
      .values
      .where((e) => projectId == null || e.$1 == projectId)
      .map((e) => e.$2)
      .toList();

  @override
  Future<void> delete(String collection, String id) async => _c(collection).remove(id);

  @override
  Future<void> deleteWhere(String collection, {required String projectId, String? field, String? equals}) async {
    _c(collection).removeWhere((k, v) => v.$1 == projectId && (field == null || v.$2[field] == equals));
  }
}

class SqliteDocStore implements DocStore {
  static const collections = [
    'projects', 'docs', 'pages', 'chunks', 'kps', 'cards', 'questions', 'wrong', 'logs', 'explain', 'chapters'
  ];
  final Database db;
  SqliteDocStore._(this.db);

  static Future<SqliteDocStore> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(p.join(dir, 'ai_flashcards.db'), version: 3, onCreate: (db, v) async {
      for (final c in collections) {
        await db.execute('CREATE TABLE $c (id TEXT PRIMARY KEY, project_id TEXT, data TEXT NOT NULL)');
        await db.execute('CREATE INDEX idx_${c}_p ON $c(project_id)');
      }
    }, onUpgrade: (db, from, to) async {
      // v2：资料加 type 字段（pdf / docx / doc），旧资料全部标记为 PDF
      if (from < 2) {
        for (final row in await db.query('docs')) {
          final j = jsonDecode(row['data'] as String) as Map<String, dynamic>;
          j['type'] ??= 'pdf';
          await db.update('docs', {'data': jsonEncode(j)}, where: 'id = ?', whereArgs: [row['id']]);
        }
      }
      // v3：新增分章方案表（每份资料一条，可手动编辑）
      if (from < 3) {
        await db.execute('CREATE TABLE IF NOT EXISTS chapters (id TEXT PRIMARY KEY, project_id TEXT, data TEXT NOT NULL)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_chapters_p ON chapters(project_id)');
      }
    });
    return SqliteDocStore._(db);
  }

  @override
  Future<void> put(String collection, String id, String projectId, Map<String, dynamic> doc) => db.insert(
      collection, {'id': id, 'project_id': projectId, 'data': jsonEncode(doc)},
      conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> putAll(String collection, List<(String, String, Map<String, dynamic>)> docs) async {
    final b = db.batch();
    for (final d in docs) {
      b.insert(collection, {'id': d.$1, 'project_id': d.$2, 'data': jsonEncode(d.$3)},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    final r = await db.query(collection, where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return null;
    return jsonDecode(r.first['data'] as String) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> list(String collection, {String? projectId}) async {
    final r = projectId == null
        ? await db.query(collection)
        : await db.query(collection, where: 'project_id = ?', whereArgs: [projectId]);
    return r.map((e) => jsonDecode(e['data'] as String) as Map<String, dynamic>).toList();
  }

  @override
  Future<void> delete(String collection, String id) => db.delete(collection, where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> deleteWhere(String collection, {required String projectId, String? field, String? equals}) async {
    if (field == null) {
      await db.delete(collection, where: 'project_id = ?', whereArgs: [projectId]);
      return;
    }
    final rows = await list(collection, projectId: projectId);
    for (final r in rows.where((r) => r[field] == equals)) {
      await delete(collection, r['id'] as String);
    }
  }
}
