import Foundation
import SQLite3

/// Used on the main actor by the app. Audio is stored beside the transactional library.
public final class MeetingStore {
    public let root: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(root.appendingPathComponent("library.sqlite").path, &db) == SQLITE_OK else {
            throw WhaleError("Could not open the meeting library.")
        }
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, date REAL NOT NULL, payload BLOB NOT NULL);")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS meeting_search USING fts5(id UNINDEXED, content, tokenize='unicode61');")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> WhaleError { WhaleError("Library error: \(String(cString: sqlite3_errmsg(db)))") }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        return result
    }
    private func bind(_ value: String, at index: Int32, to stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
    public func save(_ meeting: Meeting) throws {
        let data = try JSONEncoder().encode(meeting)
        try execute("BEGIN IMMEDIATE")
        do {
            let stmt = try statement("INSERT OR REPLACE INTO meetings (id,date,payload) VALUES (?,?,?)")
            defer { sqlite3_finalize(stmt) }
            bind(meeting.id.uuidString, at: 1, to: stmt)
            sqlite3_bind_double(stmt, 2, meeting.date.timeIntervalSince1970)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(data.count), transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            let deletion = try statement("DELETE FROM meeting_search WHERE id=?")
            defer { sqlite3_finalize(deletion) }
            bind(meeting.id.uuidString, at: 1, to: deletion)
            guard sqlite3_step(deletion) == SQLITE_DONE else { throw failure() }
            let index = try statement("INSERT INTO meeting_search (id,content) VALUES (?,?)")
            defer { sqlite3_finalize(index) }
            bind(meeting.id.uuidString, at: 1, to: index)
            bind(meeting.searchableText, at: 2, to: index)
            guard sqlite3_step(index) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func load(query: String = "") throws -> [Meeting] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let sql = words.isEmpty ? "SELECT payload FROM meetings ORDER BY date DESC" :
            "SELECT payload FROM meetings WHERE id IN (SELECT id FROM meeting_search WHERE meeting_search MATCH ?) ORDER BY date DESC"
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        if !words.isEmpty {
            // Quote user input: punctuation is text, never FTS syntax.
            let match = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
            bind(match, at: 1, to: stmt)
        }
        var results: [Meeting] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { throw failure() }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            results.append(try JSONDecoder().decode(Meeting.self, from: data))
        }
        return results
    }
    public func folder(for id: UUID) throws -> URL {
        let url = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public func delete(_ id: UUID) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["meetings", "meeting_search"] {
                let stmt = try statement("DELETE FROM \(table) WHERE id=?")
                defer { sqlite3_finalize(stmt) }
                bind(id.uuidString, at: 1, to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        let folder = root.appendingPathComponent("Recordings/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    public func recoverInterrupted() throws {
        for var meeting in try load() where meeting.status == .recording || meeting.status == .processing {
            meeting.status = .interrupted
            meeting.error = "Whale closed before this meeting finished. Saved audio and transcript are retained; retry processing to recover them."
            try save(meeting)
        }
    }
}
