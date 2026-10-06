import Foundation
import UIKit
import ImageIO

extension CodingUserInfoKey { static let photoMigration = CodingUserInfoKey(rawValue: "sellpilot.photoMigration")! }

/// Counts photos moved out of legacy inline payloads while decoding, so the store knows to rewrite the payload.
final class PhotoMigrationTracker { var count = 0 }

/// Stores photo bytes as individual files (`<photo-id>.original` / `<photo-id>.preview`) instead of inside the item payload.
final class PhotoStorage: @unchecked Sendable {
    enum Kind: String, CaseIterable { case original, preview }

    /// Replace in tests (and UI-test launches) to keep photos out of the real library.
    static var shared = PhotoStorage.makeDefault()

    let root: URL
    private let cache = NSCache<NSString, UIImage>()

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func makeDefault() -> PhotoStorage {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return PhotoStorage(root: base.appendingPathComponent("SellPilotPhotos", isDirectory: true))
    }

    private func url(id: UUID, kind: Kind) -> URL { root.appendingPathComponent("\(id.uuidString).\(kind.rawValue)") }

    func write(_ data: Data, id: UUID, kind: Kind) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url(id: id, kind: kind), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read(id: UUID, kind: Kind) -> Data? { try? Data(contentsOf: url(id: id, kind: kind)) }
    func exists(id: UUID, kind: Kind) -> Bool { FileManager.default.fileExists(atPath: url(id: id, kind: kind).path) }
    func byteCount(id: UUID, kind: Kind) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url(id: id, kind: kind).path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Display image downsampled to `maxPixel`, from the preview file when present, else the original.
    func thumbnail(id: UUID, maxPixel: Int) -> UIImage? {
        let key = "\(id.uuidString)-\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let source = [Kind.preview, .original].lazy.compactMap { kind in
            CGImageSourceCreateWithURL(self.url(id: id, kind: kind) as CFURL, nil)
        }.first
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    func delete(ids: some Sequence<UUID>) {
        for id in ids { for kind in Kind.allCases { try? FileManager.default.removeItem(at: url(id: id, kind: kind)) } }
    }

    /// Removes photo files no item references (left by crashes or abandoned imports). Only touches files named
    /// like photo files, and returns how many it removed.
    @discardableResult func sweep(keeping referenced: Set<UUID>) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names {
            let url = URL(fileURLWithPath: name)
            guard Kind(rawValue: url.pathExtension) != nil, let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            if (try? FileManager.default.removeItem(at: root.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
