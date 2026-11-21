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

  /// 原样导出一个集合（含 projectId），用于备份。
  Future<List<StoreRow>> rows(String collection, {String? projectId});

  /// 在一个事务里执行：先清空 [clear] 里的集合，再删除 [deletes]，再写入 [puts]。
  /// 任何一步失败都整体回滚，不会留下一半的数据。
  Future<void> applyAtomic({List<String> clear = const [], List<(String, String)> deletes = const [], List<(String, StoreRow)> puts = const []});

  /// 所有集合名。
  static const allCollections = [
    'projects', 'docs', 'pages', 'chunks', 'kps', 'cards', 'questions', 'wrong', 'logs', 'explain', 'chapters'
  ];
}

typedef StoreRow = (String id, String projectId, Map<String, dynamic> doc);

class MemoryDocStore implements DocStore {
  Map<String, Map<String, (String, Map<String, dynamic>)>> _data = {};
  /// 测试用：在写入第 N 条时抛错，验证事务回滚。
  int? failAfterPuts;

  @override
  Future<List<StoreRow>> rows(String collection, {String? projectId}) async => [
        for (final e in _c(collection).entries)
          if (projectId == null || e.value.$1 == projectId)
            (e.key, e.value.$1, jsonDecode(jsonEncode(e.value.$2)) as Map<String, dynamic>)
      ];

  @override
  Future<void> applyAtomic({List<String> clear = const [], List<(String, String)> deletes = const [], List<(String, StoreRow)> puts = const []}) async {
    // 在副本上操作，全部成功后再替换
    final copy = {for (final e in _data.entries) e.key: Map.of(e.value)};
    for (final c in clear) {
      copy[c] = {};
    }
    for (final d in deletes) {
      copy[d.$1]?.remove(d.$2);
    }
    var n = 0;
    for (final p in puts) {
      if (failAfterPuts != null && n++ >= failAfterPuts!) throw StateError('模拟写入失败');
      copy.putIfAbsent(p.$1, () => {})[p.$2.$1] = (p.$2.$2, jsonDecode(jsonEncode(p.$2.$3)) as Map<String, dynamic>);
    }
    _data = copy;
  }

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
  /// 数据库结构版本；备份文件里也写这个数，用来判断能否导入。
  static const schemaVersion = 4;
  static const collections = DocStore.allCollections;
  final Database db;
  SqliteDocStore._(this.db);

  static Future<SqliteDocStore> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(p.join(dir, 'ai_flashcards.db'), version: schemaVersion, onCreate: (db, v) async {
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
      // v3：新增分章方案表；之后的版本新增集合也走这里（缺哪张表补哪张）
      for (final c in collections) {
        await db.execute('CREATE TABLE IF NOT EXISTS $c (id TEXT PRIMARY KEY, project_id TEXT, data TEXT NOT NULL)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_${c}_p ON $c(project_id)');
      }
      // v4：解释缓存变成「解释历史」，补上时间字段
      if (from < 4) {
        final now = DateTime.now().toIso8601String();
        for (final row in await db.query('explain')) {
          final j = jsonDecode(row['data'] as String) as Map<String, dynamic>;
          j['createdAt'] ??= now;
          j['updatedAt'] ??= j['createdAt'];
          await db.update('explain', {'data': jsonEncode(j)}, where: 'id = ?', whereArgs: [row['id']]);
        }
      }
    });
    return SqliteDocStore._(db);
  }

  @override
  Future<List<StoreRow>> rows(String collection, {String? projectId}) async {
    final r = projectId == null
        ? await db.query(collection)
        : await db.query(collection, where: 'project_id = ?', whereArgs: [projectId]);
    return [
      for (final e in r)
        (e['id'] as String, (e['project_id'] as String?) ?? '', jsonDecode(e['data'] as String) as Map<String, dynamic>)
    ];
  }

  @override
  Future<void> applyAtomic({List<String> clear = const [], List<(String, String)> deletes = const [], List<(String, StoreRow)> puts = const []}) =>
      db.transaction((txn) async {
        for (final c in clear) {
          await txn.delete(c);
        }
        final b = txn.batch();
        for (final d in deletes) {
          b.delete(d.$1, where: 'id = ?', whereArgs: [d.$2]);
        }
        for (final p in puts) {
          b.insert(p.$1, {'id': p.$2.$1, 'project_id': p.$2.$2, 'data': jsonEncode(p.$2.$3)},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await b.commit(noResult: true);
      });

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
