import CSwiftSQL
import SwiftSQL

// swift_sql's SQLite as an Isomer guest links it, run under a WASI engine
// with a directory mapped in as /tmp: a database in a file, written, closed
// and opened again, with full-text search (FTS5), a second connection beside
// the first, an async query (off the caller's executor, as a single-threaded
// module runs it), and the "unix-none" VFS (no lock files) by default.
// Each line prints "ok" or what differed.

func check(_ name: String, _ actual: String, _ expected: String) {
    print(actual == expected ? "ok   \(name)" : "FAIL \(name): got \(actual.debugDescription), want \(expected.debugDescription)")
}

func value(_ database: Database, _ sql: String) -> String {
    do {
        return try database.query(sql) { $0.text(0) ?? "NULL" }.joined(separator: ",")
    } catch {
        return "\(error)"
    }
}

@main
struct SQLiteFileCheck {
    static func main() async {
        let path = "/tmp/cache.sqlite"
        check("default VFS", sqlite3_vfs_find(nil).map { String(cString: $0.pointee.zName) } ?? "none", "unix-none")
        do {
            let database = try Database(path: path)
            try database.execute("CREATE TABLE rows(id INTEGER PRIMARY KEY, session TEXT, body TEXT)")
            try database.execute("CREATE VIRTUAL TABLE rows_fts USING fts5(body, content='rows', content_rowid='id')")
            try database.transaction { connection in
                for index in 1...150 {
                    try connection.run(
                        "INSERT INTO rows(session, body) VALUES (?, ?)",
                        "s\(index % 3)", "row \(index) \(index == 42 ? "pagination cache" : "plain")")
                }
                try connection.execute("INSERT INTO rows_fts(rows_fts) VALUES('rebuild')")
            }
            check("insert in a transaction", value(database, "SELECT count(*) FROM rows"), "150")
            check("match", value(database, "SELECT rowid FROM rows_fts WHERE rows_fts MATCH 'pagination'"), "42")
            // A page of 50 from the end, as a transcript reads backwards.
            check("page", value(database, "SELECT count(*) FROM (SELECT id FROM rows ORDER BY id DESC LIMIT 50 OFFSET 100)"), "50")
            let second = try Database(path: path)
            check("second connection reads", value(second, "SELECT count(*) FROM rows"), "150")
            check("second connection writes", "\(try second.run("DELETE FROM rows WHERE session = ?", "s0"))", "50")
            check("first sees it", value(database, "SELECT count(*) FROM rows"), "100")
            let counted = try await database.perform { connection in
                try connection.query("SELECT count(*) FROM rows WHERE session = ?", "s1") { $0.int(0) }
            }
            check("perform, off the caller's executor", "\(counted)", "[50]")
            second.close()
            database.close()
            check("closed", "\((try? database.execute("SELECT 1")) == nil)", "true")
        } catch {
            print("FAIL \(error)")
        }
        do {
            let reopened = try Database(path: path)
            check("persisted", value(reopened, "SELECT count(*) FROM rows"), "100")
            check("journal mode", value(reopened, "PRAGMA journal_mode"), "delete")
            check("integrity", value(reopened, "PRAGMA integrity_check"), "ok")
        } catch {
            print("FAIL reopening: \(error)")
        }
        print("ok")
    }
}
