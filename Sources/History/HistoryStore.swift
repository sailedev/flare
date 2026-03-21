import AppKit
import SQLite

struct HistoryItem: Identifiable {
    let id: Int64
    let filename: String
    let timestamp: Date
    let captureMode: String
    let appName: String
}

/// Persists screenshot history using file system + SQLite index.
final class HistoryStore: ObservableObject {
    private let settingsStore: SettingsStore
    private var db: Connection?

    // SQLite table definitions
    private let screenshots = Table("screenshots")
    private let colId = Expression<Int64>("id")
    private let colFilename = Expression<String>("filename")
    private let colTimestamp = Expression<Double>("timestamp")
    private let colCaptureMode = Expression<String>("captureMode")
    private let colAppName = Expression<String>("appName")

    @Published var items: [HistoryItem] = []

    private var historyFolderURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Flare/History", isDirectory: true)
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        setupDatabase()
        refreshItems()
    }

    // MARK: - Setup

    private func setupDatabase() {
        do {
            let folder = historyFolderURL
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let dbPath = folder.deletingLastPathComponent().appendingPathComponent("history.db").path
            db = try Connection(dbPath)

            try db?.run(screenshots.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colFilename)
                t.column(colTimestamp)
                t.column(colCaptureMode)
                t.column(colAppName)
            })
        } catch {
        }
    }

    // MARK: - Save

    func save(image: NSImage, captureMode: String, appName: String) {
        guard let db else { return }

        let timestamp = Date().timeIntervalSince1970
        let filename = "screenshot_\(Int(timestamp * 1000)).png"
        let fileURL = historyFolderURL.appendingPathComponent(filename)

        // Write image file (use CGImageDestination to avoid expensive TIFF intermediate)
        guard let pngData = OutputEngine.encodePNG(from: image) else { return }

        do {
            try pngData.write(to: fileURL)

            try db.run(screenshots.insert(
                colFilename <- filename,
                colTimestamp <- timestamp,
                colCaptureMode <- captureMode,
                colAppName <- appName
            ))

            autoCleanup()
            refreshItems()
        } catch {
        }
    }

    // MARK: - Fetch

    func fetchRecent(limit: Int = 100) -> [HistoryItem] {
        guard let db else { return [] }

        do {
            let query = screenshots.order(colTimestamp.desc).limit(limit)
            return try db.prepare(query).map { row in
                HistoryItem(
                    id: row[colId],
                    filename: row[colFilename],
                    timestamp: Date(timeIntervalSince1970: row[colTimestamp]),
                    captureMode: row[colCaptureMode],
                    appName: row[colAppName]
                )
            }
        } catch {
            return []
        }
    }

    func loadImage(for item: HistoryItem) -> NSImage? {
        let fileURL = historyFolderURL.appendingPathComponent(item.filename)
        return NSImage(contentsOf: fileURL)
    }

    // MARK: - Delete

    func delete(item: HistoryItem) {
        guard let db else { return }

        // Delete DB row first - an orphaned file is less harmful than
        // an orphaned DB entry pointing to a missing file
        let row = screenshots.filter(colId == item.id)
        _ = try? db.run(row.delete())

        let fileURL = historyFolderURL.appendingPathComponent(item.filename)
        try? FileManager.default.removeItem(at: fileURL)

        refreshItems()
    }

    func clearAll() {
        guard let db else { return }

        // Delete all files
        let folder = historyFolderURL
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Clear database
        _ = try? db.run(screenshots.delete())
        refreshItems()
    }

    // MARK: - Auto-cleanup

    private func autoCleanup() {
        guard let db else { return }
        let limit = settingsStore.historyLimit

        do {
            let count = try db.scalar(screenshots.count)
            if count > limit {
                let excess = count - limit
                let oldestQuery = screenshots.order(colTimestamp.asc).limit(excess)
                let oldRows = try db.prepare(oldestQuery).map { ($0[colId], $0[colFilename]) }

                for (id, filename) in oldRows {
                    let fileURL = historyFolderURL.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: fileURL)
                    try db.run(screenshots.filter(colId == id).delete())
                }
            }
        } catch {
        }
    }

    // MARK: - Refresh Published Items

    private func refreshItems() {
        items = fetchRecent()
    }
}
