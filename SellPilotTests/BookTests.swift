import XCTest
import SwiftData
import UIKit
@testable import SellPilot

private final class BookStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var urls: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.urls.append(request.url!)
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct FakeCatalog: BookCatalogService {
    var details: BookDetails?
    var fails = false
    func lookup(isbn: String) async throws -> BookDetails? { if fails { throw ServiceError.invalid("down") }; return details }
}

final class BookTests: XCTestCase {
    private var containers: [ModelContainer] = []
    override func setUp() { BookStub.handler = nil; BookStub.urls = [] }

    private func session() -> URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BookStub.self]; return URLSession(configuration: config) }
    private let atomic = BookDetails(isbn: "9780735211292", title: "Atomic Habits", authors: ["James Clear"], publisher: "Avery", year: "2018")

    // MARK: ISBN

    func testISBN13ChecksumAndFormatting() {
        XCTAssertEqual(ISBN.normalize("978-0-7352-1129-2"), "9780735211292")
        XCTAssertEqual(ISBN.normalize(" 9780735211292\n"), "9780735211292")
        XCTAssertNil(ISBN.normalize("9780735211293"), "wrong check digit")
        XCTAssertNil(ISBN.normalize("4006381333931"), "an ordinary product barcode, not a book")
        XCTAssertNil(ISBN.normalize("12345"))
    }
    func testISBN10IsConvertedToISBN13() {
        XCTAssertEqual(ISBN.normalize("0-306-40615-2"), "9780306406157")
        XCTAssertEqual(ISBN.normalize("080442957X"), "9780804429573")
        XCTAssertNil(ISBN.normalize("0306406153"))
    }

    // MARK: Catalog

    func testOpenLibraryDetailsAreParsed() async throws {
        BookStub.handler = { _ in (200, Data(#"{"ISBN:9780735211292":{"title":"Atomic Habits","authors":[{"name":"James Clear"}],"publishers":[{"name":"Avery"}],"publish_date":"October 16, 2018"}}"#.utf8)) }
        let details = try await PublicBookCatalog(session: session()).lookup(isbn: "9780735211292")
        XCTAssertEqual(details, atomic); XCTAssertEqual(details?.listingTitle, "Atomic Habits by James Clear")
        XCTAssertEqual(BookStub.urls.count, 1)
    }
    func testGoogleBooksIsUsedWhenOpenLibraryHasNothing() async throws {
        BookStub.handler = { request in
            request.url!.host == "openlibrary.org" ? (200, Data("{}".utf8))
                : (200, Data(#"{"items":[{"volumeInfo":{"title":"Atomic Habits","authors":["James Clear"],"publisher":"Avery","publishedDate":"2018-10-16"}}]}"#.utf8))
        }
        let details = try await PublicBookCatalog(session: session()).lookup(isbn: "9780735211292")
        XCTAssertEqual(details, atomic)
    }
    func testMissingAuthorIsFilledFromOpenLibrarySearch() async throws {
        BookStub.handler = { request in
            request.url!.path.contains("search.json") ? (200, Data(#"{"docs":[{"author_name":["James Clear"]}]}"#.utf8))
                : (200, Data(#"{"ISBN:9780735211292":{"title":"Atomic Habits","publishers":[{"name":"Avery"}],"publish_date":"2018"}}"#.utf8))
        }
        let details = try await PublicBookCatalog(session: session()).lookup(isbn: "9780735211292")
        XCTAssertEqual(details?.authors, ["James Clear"]); XCTAssertEqual(details?.listingTitle, "Atomic Habits by James Clear")
    }
    func testUnknownISBNGivesNil() async throws {
        BookStub.handler = { request in request.url!.host == "openlibrary.org" ? (200, Data("{}".utf8)) : (200, Data(#"{"totalItems":0}"#.utf8)) }
        let details = try await PublicBookCatalog(session: session()).lookup(isbn: "9780735211292")
        XCTAssertNil(details)
    }

    // MARK: Workflow

    @MainActor private func workflow(books: (any BookCatalogService)?) throws -> SellingWorkflow {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        var services = AppServices(); services.books = books
        return SellingWorkflow(item: SellItem(), store: ItemStore(context: container.mainContext), services: services)
    }

    @MainActor func testTypedISBNFillsTheBookDetails() async throws {
        let flow = try workflow(books: FakeCatalog(details: atomic))
        await flow.lookUpISBN("978-0-7352-1129-2")
        XCTAssertEqual(flow.item.isbn, "9780735211292"); XCTAssertEqual(flow.item.title, "Atomic Habits by James Clear")
        XCTAssertEqual(flow.item.category, "Books"); XCTAssertEqual(flow.item.brand, "Avery"); XCTAssertEqual(flow.item.bookDetails, atomic)
    }
    @MainActor func testInvalidISBNIsExplainedAndNothingIsSet() async throws {
        let flow = try workflow(books: FakeCatalog(details: atomic))
        await flow.lookUpISBN("9780735211293")
        XCTAssertNil(flow.item.isbn); XCTAssertTrue(try XCTUnwrap(flow.isbnStatus).contains("isn't a valid ISBN"))
    }
    @MainActor func testUnknownOrUnreachableCatalogKeepsTheISBNAndTheSellersOwnTitle() async throws {
        for catalog in [FakeCatalog(details: nil), FakeCatalog(details: nil, fails: true)] {
            let flow = try workflow(books: catalog); flow.item.title = "My book"
            await flow.lookUpISBN("9780735211292")
            XCTAssertEqual(flow.item.isbn, "9780735211292"); XCTAssertEqual(flow.item.title, "My book"); XCTAssertNil(flow.item.bookDetails)
        }
    }
    @MainActor func testClearingTheFieldRemovesTheISBN() async throws {
        let flow = try workflow(books: FakeCatalog(details: atomic))
        await flow.lookUpISBN("9780735211292"); await flow.lookUpISBN("  ")
        XCTAssertNil(flow.item.isbn); XCTAssertNil(flow.item.bookDetails)
    }

    // MARK: Comps and eBay details

    func testBrowseSearchesByISBNAndSkipsTheTitleFilter() async throws {
        var seen: [URL] = []
        BookStub.handler = { request in
            seen.append(request.url!)
            if request.url!.path.contains("oauth2/token") { return (200, Data(#"{"access_token":"t","expires_in":7200}"#.utf8)) }
            let items = (0..<6).map { ["itemId": "v1|\($0)", "title": "Some unrelated listing words \($0)", "price": ["value": "\(10 + $0)", "currency": "USD"], "conditionId": "3000", "itemWebUrl": "https://www.ebay.com/itm/\($0)"] as [String: Any] }
            return (200, try! JSONSerialization.data(withJSONObject: ["itemSummaries": items]))
        }
        let browse = EbayBrowseMarketResearchService(configuration: .init(credentials: .init(appID: "a", certID: "c")), session: session())
        var item = SellItem(); item.title = "Atomic Habits by James Clear"; item.isbn = "9780735211292"
        let comps = try await FilteredMarketResearchService(base: browse, filter: TitleComparableFilter()).research(item: item)
        let search = try XCTUnwrap(seen.first { $0.path.contains("item_summary/search") }).absoluteString
        XCTAssertTrue(search.contains("gtin=9780735211292")); XCTAssertFalse(search.contains("q="))
        XCTAssertEqual(comps.count, 6, "exact-ISBN listings are not dropped by title rules"); XCTAssertTrue(comps.allSatisfy { $0.verifiedMatch == true })
    }
    func testBrowseFallsBackToTitlesWhenTheISBNFindsTooFew() async throws {
        var searches: [String] = []
        BookStub.handler = { request in
            if request.url!.path.contains("oauth2/token") { return (200, Data(#"{"access_token":"t","expires_in":7200}"#.utf8)) }
            searches.append(request.url!.absoluteString)
            let count = request.url!.absoluteString.contains("gtin=") ? 1 : 6
            let items = (0..<count).map { ["itemId": "v1|\($0)", "title": "Atomic Habits \($0)", "price": ["value": "12", "currency": "USD"], "conditionId": "3000"] as [String: Any] }
            return (200, try! JSONSerialization.data(withJSONObject: ["itemSummaries": items]))
        }
        let browse = EbayBrowseMarketResearchService(configuration: .init(credentials: .init(appID: "a", certID: "c")), session: session())
        var item = SellItem(); item.title = "Atomic Habits"; item.isbn = "9780735211292"
        let comps = try await browse.research(item: item)
        XCTAssertEqual(comps.count, 6); XCTAssertTrue(searches.first!.contains("gtin=")); XCTAssertTrue(searches.last!.contains("q=Atomic"))
    }
    func testBookFactsFillEbayBookAspects() {
        var item = SellItem(); item.isbn = "9780735211292"; item.bookDetails = atomic; item.title = "Atomic Habits by James Clear"
        let aspects = [EbayAspect(name: "Author", required: true, selectionOnly: false, multiValue: false, values: []),
                       EbayAspect(name: "ISBN", required: false, selectionOnly: false, multiValue: false, values: []),
                       EbayAspect(name: "Publication Year", required: false, selectionOnly: false, multiValue: false, values: []),
                       EbayAspect(name: "Publisher", required: true, selectionOnly: false, multiValue: false, values: []),
                       EbayAspect(name: "Binding", required: false, selectionOnly: false, multiValue: false, values: [])]
        let specifics = EbaySpecifics.prefill(item: item, existing: [:], aspects: aspects)
        XCTAssertEqual(specifics["Author"], "James Clear"); XCTAssertEqual(specifics["ISBN"], "9780735211292"); XCTAssertNil(specifics["Publication Year"], "optional and unreliable, so not sent silently"); XCTAssertEqual(specifics["Publisher"], "Avery")
        XCTAssertNil(specifics["Binding"])
    }

    // MARK: Barcode

    /// Draws a real EAN-13 barcode, so the scanner is tested on an actual image rather than a stub.
    private func ean13Image(_ digits: String) -> Data {
        let l = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
        let g = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
        let r = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
        let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
        let d = digits.compactMap { Int(String($0)) }
        var bits = "101"
        for (i, ch) in parity[d[0]].enumerated() { bits += ch == "L" ? l[d[i + 1]] : g[d[i + 1]] }
        bits += "01010"
        for i in 7...12 { bits += r[d[i]] }
        bits += "101"
        let unit: CGFloat = 4, quiet: CGFloat = 40, height: CGFloat = 240
        let size = CGSize(width: CGFloat(bits.count) * unit + quiet * 2, height: height + quiet * 2)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.95) { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for (i, bit) in bits.enumerated() where bit == "1" { context.fill(CGRect(x: quiet + CGFloat(i) * unit, y: quiet, width: unit, height: height)) }
        }
    }

    func testBarcodeReaderFindsTheISBNInAPhoto() async throws {
        let found = await BarcodeReader.isbn(in: ean13Image("9780735211292"))
        XCTAssertEqual(found, "9780735211292")
    }
    func testBarcodeReaderIgnoresNonBookBarcodes() async throws {
        let found = await BarcodeReader.isbn(in: ean13Image("4006381333931"))
        XCTAssertNil(found)
    }
    @MainActor func testScanningAPhotoSetsTheISBNAndDetails() async throws {
        let flow = try workflow(books: FakeCatalog(details: atomic))
        await flow.scanForISBN(in: ean13Image("9780735211292"))
        XCTAssertEqual(flow.item.isbn, "9780735211292"); XCTAssertEqual(flow.item.title, "Atomic Habits by James Clear")
    }
}
