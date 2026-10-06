import Foundation
import ImageIO
import UniformTypeIdentifiers
struct ListingExportService {
    func export(_ prepared: PreparedListing) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SellPilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = folder.appendingPathComponent("listing.txt")
        try prepared.draft.fullText.write(to: text, atomically: true, encoding: .utf8)
        let json = folder.appendingPathComponent("listing.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(prepared.draft).write(to: json, options: .atomic)
        var urls = [text, json]
        for (index, photo) in prepared.photos.enumerated() { let source = CGImageSourceCreateWithData(photo.originalData as CFData, nil)
            let type = source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
            let suffix = type?.preferredFilenameExtension ?? "image"
            let url = folder.appendingPathComponent(String(format: "%02d-original.%@", index + 1, suffix)); try photo.originalData.write(to: url, options: .atomic); urls.append(url) }
        return urls
    }
}
