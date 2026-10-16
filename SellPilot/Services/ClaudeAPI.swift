import Foundation

/// Transport shared by the Claude-backed services: one retry on transient failures and user-readable errors.
enum ClaudeAPI {
    static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static func request(endpoint: URL, apiKey: String, timeout: TimeInterval, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504, 529]

    static func send(_ request: URLRequest, session: URLSession, retryDelay: Duration) async throws -> Data {
        for attempt in 0...1 {
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch let error as URLError {
                if attempt == 0, [.timedOut, .networkConnectionLost].contains(error.code) { try await Task.sleep(for: retryDelay); continue }
                throw ServiceError.invalid(message(for: error))
            }
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalid("Unexpected response from the identification service.") }
            if (200..<300).contains(http.statusCode) { return data }
            if attempt == 0, retryableStatuses.contains(http.statusCode) { try await Task.sleep(for: retryDelay); continue }
            throw ServiceError.invalid(message(status: http.statusCode, body: data))
        }
        throw ServiceError.invalid("The identification service is unavailable. Try again shortly.")
    }

    /// Finds the input of the named tool call in a Messages API response.
    static func toolInput(named name: String, in data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]],
              let tool = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == name }),
              let input = tool["input"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: input)
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: "No internet connection. Check your connection and try again."
        case .timedOut: "Identification took too long. Try again, or use fewer photos."
        default: "Could not reach the identification service: \(error.localizedDescription)"
        }
    }

    private static func message(status: Int, body: Data) -> String {
        let detail = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        switch status {
        case 401, 403: return "The identification API key was rejected. Check it in Settings."
        case 413: return "The photos are too large to analyze. Remove a few and try again."
        case 429: return "Identification is busy right now. Try again in a moment."
        case 500...599: return "The identification service is temporarily unavailable. Try again shortly."
        default: return "Identification failed (\(status))" + (detail.map { ": \($0)" } ?? ".")
        }
    }
}
