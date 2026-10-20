// SQLite in a file of the app's (swift_sql's SwiftSQL, on WASI with the
// "unix-none" VFS), in Application Support as an iOS app's cache would be:
// each launch adds a row and a 20 KB blob, so the database grows across the
// web's 64 KiB storage blocks, and finds every row of the launches before it,
// by count and by full-text search (FTS5).

import Foundation
import SwiftSQL

extension FileChecks {
    mutating func checkSQLite(launch: Int) {
        let path = URL.applicationSupportDirectory.appending(path: "probe.sqlite").path
        let database: Database
        do {
            database = try Database(path: path)
        } catch {
            lines.append("FAIL sqlite open: \(error)")
            return
        }
        defer { database.close() }
        func run(_ sql: String) -> String {
            do {
                try database.execute(sql)
                return "ok"
            } catch {
                return (error as? SQLiteError)?.message ?? "\(error)"
            }
        }
        func value(_ sql: String) -> String {
            do {
                return try database.query(sql) { $0.text(0) ?? "NULL" }.first ?? "no row"
            } catch {
                return (error as? SQLiteError)?.message ?? "\(error)"
            }
        }
        check("sqlite schema", run("""
            CREATE TABLE IF NOT EXISTS launches(id INTEGER PRIMARY KEY, body TEXT, blob BLOB);
            CREATE VIRTUAL TABLE IF NOT EXISTS launches_fts USING fts5(body);
            """), "ok")
        check("sqlite kept", value("SELECT count(*) FROM launches"), "\(launch - 1)")
        check("sqlite insert", run("""
            BEGIN;
            INSERT INTO launches(body, blob) VALUES('launch \(launch) of the probe', randomblob(20000));
            INSERT INTO launches_fts(body) VALUES('launch \(launch) of the probe');
            COMMIT;
            """), "ok")
        check("sqlite count", value("SELECT count(*) FROM launches"), "\(launch)")
        check("sqlite search", value("SELECT count(*) FROM launches_fts WHERE launches_fts MATCH 'probe'"), "\(launch)")
        check("sqlite integrity", value("PRAGMA integrity_check"), "ok")
        check("sqlite no lock files", "\((try? FileManager.default.contentsOfDirectory(atPath: URL.applicationSupportDirectory.path))?.filter { $0.hasPrefix("probe.sqlite") }.sorted() ?? [])", "[\"probe.sqlite\"]")
    }
}
