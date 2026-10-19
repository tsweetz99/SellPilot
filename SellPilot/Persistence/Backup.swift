import Foundation

enum BackupError: LocalizedError {
    case notABackup, damaged
    var errorDescription: String? {
        switch self {
        case .notABackup: "This file isn't a SellPilot backup."
        case .damaged: "This backup file is damaged or incomplete, so nothing was restored."
        }
    }
}

struct BackupSummary: Equatable { var added = 0, updated = 0, kept = 0, photos = 0 }

/// One file holding every item and its photos. It never holds API keys or the eBay sign-in, which stay in the Keychain.
///
/// Layout: the text `SPBK1`, then records of `[name length: 4 bytes][name][data length: 8 bytes][data]`, integers big-endian.
/// The first record is `items.json`; the rest are `photos/<photo id>.original` or `.preview`. A damaged or hostile file can't
/// write outside the photo folder, because only names of exactly that shape are accepted and the id is parsed as a UUID.
enum BackupArchive {
    private static let magic = Data("SPBK1\n".utf8)
    private static let itemsName = "items.json"
    private static let maxName = 128
    private static let maxRecord: UInt64 = 400_000_000

    // MARK: Write

    static func write(items: [SellItem], photos: PhotoStorage, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: magic)
        try record(itemsName, try JSONEncoder().encode(items), to: handle)
        var written = Set<String>()
        for photo in items.flatMap(\.photos) {
            for kind in PhotoStorage.Kind.allCases {
                let name = "photos/\(photo.id.uuidString).\(kind.rawValue)"
                guard !written.contains(name), let data = photos.read(id: photo.id, kind: kind) else { continue }
                written.insert(name)
                try record(name, data, to: handle)
            }
        }
    }

    private static func record(_ name: String, _ data: Data, to handle: FileHandle) throws {
        let nameData = Data(name.utf8)
        var header = Data()
        var nameLength = UInt32(nameData.count).bigEndian, dataLength = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &nameLength) { header.append(contentsOf: $0) }
        header.append(nameData)
        withUnsafeBytes(of: &dataLength) { header.append(contentsOf: $0) }
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
    }

    // MARK: Read

    /// Reads a backup. `shouldTake` decides, per item, whether to restore it; only photos of taken items are written.
    static func read(from url: URL, photos: PhotoStorage, shouldTake: (SellItem) -> Bool) throws -> (all: [SellItem], taken: [SellItem], photos: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: magic.count) == magic else { throw BackupError.notABackup }
        guard let first = try next(handle), first.name == itemsName else { throw BackupError.damaged }
        let decoder = JSONDecoder(); decoder.userInfo[.photoMigration] = PhotoMigrationTracker()
        guard let all = try? decoder.decode([SellItem].self, from: first.data) else { throw BackupError.damaged }
        let taken = all.filter(shouldTake)
        var wanted = Set<UUID>(); for photo in taken.flatMap(\.photos) { wanted.insert(photo.id) }
        var restored = 0
        while let record = try next(handle) {
            guard let (id, kind) = photoName(record.name), wanted.contains(id) else { continue }
            try photos.write(record.data, id: id, kind: kind)
            if kind == .original { restored += 1 }
        }
        return (all, taken, restored)
    }

    private static func photoName(_ name: String) -> (UUID, PhotoStorage.Kind)? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "photos" else { return nil }
        let file = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard file.count == 2, let id = UUID(uuidString: String(file[0])), let kind = PhotoStorage.Kind(rawValue: String(file[1])) else { return nil }
        return (id, kind)
    }

    /// The next record, or nil at a clean end of file. A cut-off record throws.
    private static func next(_ handle: FileHandle) throws -> (name: String, data: Data)? {
        guard let head = try handle.read(upToCount: 4), !head.isEmpty else { return nil }
        guard head.count == 4 else { throw BackupError.damaged }
        let nameLength = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard nameLength > 0, nameLength <= maxName, let nameData = try exactly(nameLength, handle), let name = String(data: nameData, encoding: .utf8),
              let lengthData = try exactly(8, handle) else { throw BackupError.damaged }
        let length = lengthData.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length <= maxRecord, let data = try exactly(Int(length), handle) else { throw BackupError.damaged }
        return (name, data)
    }

    private static func exactly(_ count: Int, _ handle: FileHandle) throws -> Data? {
        if count == 0 { return Data() }
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: min(1 << 20, count - result.count)), !chunk.isEmpty else { return nil }
            result.append(chunk)
        }
        return result
    }
}

@MainActor enum BackupService {
    private static let lastKey = "lastBackupDate"
    static var lastBackup: Date? {
        get { UserDefaults.standard.object(forKey: lastKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }
    /// A gentle nudge: there are items and no backup in the last two weeks.
    static func needsReminder(itemCount: Int, now: Date = Date()) -> Bool {
        guard itemCount > 0 else { return false }
        guard let last = lastBackup else { return true }
        return now.timeIntervalSince(last) > 14 * 24 * 3600
    }

    static func fileName(now: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return "SellPilot-Backup-\(formatter.string(from: now)).sellpilot"
    }

    /// Writes every item and photo to a temporary file for the seller to save to Files or iCloud Drive.
    static func export(store: ItemStore) async throws -> URL {
        let items = store.items, photos = PhotoStorage.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName())
        try await Task.detached(priority: .userInitiated) { try BackupArchive.write(items: items, photos: photos, to: url) }.value
        lastBackup = Date()
        return url
    }

    /// Restores a backup without losing newer work: an item already on this phone is replaced only by a newer copy.
    static func restore(from url: URL, into store: ItemStore) async throws -> BackupSummary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let local = Dictionary(store.items.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        let photos = PhotoStorage.shared
        let result = try await Task.detached(priority: .userInitiated) {
            try BackupArchive.read(from: url, photos: photos) { item in local[item.id].map { $0 < item.updatedAt } ?? true }
        }.value
        try store.restore(result.taken)
        let added = result.taken.filter { local[$0.id] == nil }.count
        return BackupSummary(added: added, updated: result.taken.count - added, kept: result.all.count - result.taken.count, photos: result.photos)
    }
}
