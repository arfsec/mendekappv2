import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/schedule.dart';

class DbService {
  DbService._();
  static final DbService instance = DbService._();

  static const String _dbName = 'mendek_arena_masteran.db';
  static const int _dbVersion = 3;
  static const String _tableName = 'schedules';

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final fullPath = join(dbPath, _dbName);

    return openDatabase(
      fullPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL,
            platform TEXT NOT NULL,
            video_id TEXT NOT NULL,
            start_hour INTEGER NOT NULL,
            start_minute INTEGER NOT NULL,
            end_hour INTEGER NOT NULL,
            end_minute INTEGER NOT NULL,
            days TEXT NOT NULL,
            is_active INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            play_minutes INTEGER NOT NULL DEFAULT 15,
            pause_minutes INTEGER NOT NULL DEFAULT 5,
            local_file_path TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN play_minutes INTEGER NOT NULL DEFAULT 15',
          );
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN pause_minutes INTEGER NOT NULL DEFAULT 5',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN local_file_path TEXT',
          );
        }
      },
    );
  }

  Future<List<Schedule>> getAllSchedules() async {
    final db = await database;
    final rows = await db.query(
      _tableName,
      orderBy: 'start_hour ASC, start_minute ASC, created_at DESC',
    );
    return rows.map((row) => Schedule.fromMap(row)).toList();
  }

  Future<Schedule?> getScheduleById(String id) async {
    final db = await database;
    final rows = await db.query(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Schedule.fromMap(rows.first);
  }

  Future<void> insertSchedule(Schedule schedule) async {
    final db = await database;
    await db.insert(
      _tableName,
      schedule.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateSchedule(Schedule schedule) async {
    final db = await database;
    await db.update(
      _tableName,
      schedule.toMap(),
      where: 'id = ?',
      whereArgs: [schedule.id],
    );
  }

  Future<void> toggleScheduleActive(String id, bool isActive) async {
    final db = await database;
    await db.update(
      _tableName,
      {'is_active': isActive ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateLocalFilePath(String id, String? filePath) async {
    final db = await database;
    await db.update(
      _tableName,
      {'local_file_path': filePath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteSchedule(String id) async {
    final db = await database;
    await db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> seedDefaultSchedulesIfEmpty() async {
    final existing = await getAllSchedules();
    if (existing.isNotEmpty) return;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final List<Schedule> defaults = [
      Schedule(
        id: 'preset_subuh_cililin',
        name: 'Masteran Subuh — Cililin & Kenari',
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        platform: 'youtube',
        videoId: 'dQw4w9WgXcQ',
        startHour: 3,
        startMinute: 30,
        endHour: 6,
        endMinute: 30,
        days: const [1, 2, 3, 4, 5, 6, 7],
        isActive: true,
        createdAt: nowMs,
        playMinutes: 15,
        pauseMinutes: 5,
      ),
      Schedule(
        id: 'preset_siang_murai',
        name: 'Isian Siang — Tengkek & Kapas Tembak',
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        platform: 'youtube',
        videoId: 'dQw4w9WgXcQ',
        startHour: 11,
        startMinute: 30,
        endHour: 14,
        endMinute: 0,
        days: const [1, 2, 3, 4, 5, 6, 7],
        isActive: true,
        createdAt: nowMs + 1,
        playMinutes: 20,
        pauseMinutes: 10,
      ),
      Schedule(
        id: 'preset_malam_istirahat',
        name: 'Masteran Malam — Pelan Kerodong',
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        platform: 'youtube',
        videoId: 'dQw4w9WgXcQ',
        startHour: 19,
        startMinute: 0,
        endHour: 22,
        endMinute: 0,
        days: const [1, 2, 3, 4, 5, 6, 7],
        isActive: false,
        createdAt: nowMs + 2,
        playMinutes: 15,
        pauseMinutes: 5,
      ),
    ];
    for (final item in defaults) {
      await insertSchedule(item);
    }
  }
}
