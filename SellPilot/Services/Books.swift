import Foundation
import Vision

/// ISBN checks. Books carry an ISBN-13 barcode (EAN-13 starting 978 or 979); older books may only print an ISBN-10.
enum ISBN {
    /// A valid ISBN-13 from whatever the seller typed or the barcode held, or nil. An ISBN-10 is converted to ISBN-13.
    static func normalize(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        if cleaned.count == 13, cleaned.allSatisfy(\.isNumber), cleaned.hasPrefix("978") || cleaned.hasPrefix("979") {
            return checkDigit(String(cleaned.prefix(12))) == cleaned.last.flatMap { Int(String($0)) } ? cleaned : nil
        }
        if cleaned.count == 10, let isbn10 = thirteen(fromTen: cleaned) { return isbn10 }
        return nil
    }

    private static func checkDigit(_ twelve: String) -> Int {
        let sum = twelve.compactMap { Int(String($0)) }.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return (10 - sum % 10) % 10
    }

    private static func thirteen(fromTen ten: String) -> String? {
        let digits = Array(ten)
        var total = 0
        for (index, character) in digits.enumerated() {
            let value = character == "X" && index == 9 ? 10 : Int(String(character))
            guard let value else { return nil }
            total += value * (10 - index)
        }
        guard total % 11 == 0 else { return nil }
        let twelve = "978" + String(ten.prefix(9))
        return twelve + String(checkDigit(twelve))
    }
}

struct BookDetails: Codable, Equatable {
    var isbn: String
    var title: String
    var authors: [String] = []
    var publisher: String? = nil
    var year: String? = nil
    /// "Title by First Author", the usual shape of an eBay book title.
    var listingTitle: String { authors.first.map { "\(title) by \($0)" } ?? title }
}

protocol BookCatalogService {
    /// Details for a valid ISBN-13, or nil when the catalog has no record of it.
    func lookup(isbn: String) async throws -> BookDetails?
}

/// Free public book catalogs, no key needed: Open Library first, Google Books if Open Library does not know the ISBN.
/// Only the ISBN is sent. No eBay data and no photos are involved.
struct PublicBookCatalog: BookCatalogService {
    var session: URLSession = .shared

    func lookup(isbn: String) async throws -> BookDetails? {
        if let found = try? await openLibrary(isbn) { return found }
        return try await googleBooks(isbn)
    }

    private func fetch(_ url: URL) async throws -> Any? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.invalid("The book catalog is not available right now.") }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func openLibrary(_ isbn: String) async throws -> BookDetails? {
        var components = URLComponents(string: "https://openlibrary.org/api/books")!
        components.queryItems = [URLQueryItem(name: "bibkeys", value: "ISBN:\(isbn)"), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "jscmd", value: "data")]
        guard let root = try await fetch(components.url!) as? [String: Any], let book = root["ISBN:\(isbn)"] as? [String: Any], let title = book["title"] as? String, !title.isEmpty else { return nil }
        let authors = (book["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let publisher = (book["publishers"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.first
        let found = BookDetails(isbn: isbn, title: title, authors: authors, publisher: publisher, year: Self.year(book["publish_date"] as? String))
        return found.authors.isEmpty ? await withAuthors(found) : found
    }

    /// Some Open Library editions list no author; its search knows the work's author by ISBN.
    private func withAuthors(_ details: BookDetails) async -> BookDetails {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [URLQueryItem(name: "isbn", value: details.isbn), URLQueryItem(name: "fields", value: "author_name"), URLQueryItem(name: "limit", value: "1")]
        guard let root = try? await fetch(components.url!) as? [String: Any], let names = (root["docs"] as? [[String: Any]])?.first?["author_name"] as? [String], !names.isEmpty else { return details }
        var result = details; result.authors = names; return result
    }

    private func googleBooks(_ isbn: String) async throws -> BookDetails? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [URLQueryItem(name: "q", value: "isbn:\(isbn)"), URLQueryItem(name: "maxResults", value: "1")]
        guard let root = try await fetch(components.url!) as? [String: Any], let volume = (root["items"] as? [[String: Any]])?.first?["volumeInfo"] as? [String: Any],
              let title = volume["title"] as? String, !title.isEmpty else { return nil }
        return BookDetails(isbn: isbn, title: title, authors: volume["authors"] as? [String] ?? [], publisher: volume["publisher"] as? String, year: Self.year(volume["publishedDate"] as? String))
    }

    static func year(_ text: String?) -> String? { text?.range(of: "(1[5-9]|20)[0-9]{2}", options: .regularExpression).map { String(text![$0]) } }
}

/// Reads a book's ISBN from a photo of its barcode, on the device. No network and no AI are involved.
enum BarcodeReader {
    static func isbn(in imageData: Data) async -> String? {
        await Task.detached(priority: .userInitiated) {
            // The newest detector first, then the older classic one: some photos (and the simulator) only decode with the latter.
            for revision in [nil, VNDetectBarcodesRequestRevision2] as [Int?] {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.ean13]
                if let revision { request.revision = revision }
                #if targetEnvironment(simulator)
                // The simulator has no neural engine or GPU for Vision; real devices use the default.
                request.usesCPUOnly = true
                #endif
                guard (try? VNImageRequestHandler(data: imageData).perform([request])) != nil else { continue }
                if let isbn = request.results?.compactMap({ $0.payloadStringValue.flatMap(ISBN.normalize) }).first { return isbn }
            }
            return nil
        }.value
    }
}
