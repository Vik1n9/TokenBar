import Foundation

enum APIError: LocalizedError {
    case noAPIKey
    case unauthorized
    case rateLimited
    case serverError(Int)
    case httpError(Int)
    /// The account has no `/v1/usage` endpoint. Not a failure — the caller falls
    /// back to the balance ledger and says nothing to the user.
    case usageEndpointUnavailable
    case networkError(String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .unauthorized: return "API key rejected"
        case .rateLimited: return "Rate limited — try again shortly"
        case .serverError(let code): return "Server error (\(code))"
        case .httpError(let code): return "HTTP error (\(code))"
        case .usageEndpointUnavailable: return "Usage endpoint not available for this account"
        case .networkError(let message): return message
        case .decodingError(let message): return "Unexpected response: \(message)"
        }
    }
}

/// Talks to the OpenAI-shaped endpoint the user configured (api.deepseek.com by
/// default). Balance is the documented call; usage is best-effort.
final class APIClient {
    static let defaultBaseURL = "https://api.deepseek.com"
    /// Responses are tiny; the cap stops a misconfigured host from streaming
    /// megabytes into memory before the decode fails anyway.
    private static let maxBodyBytes = 64 * 1024

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "deepseek.baseURL") ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultBaseURL : trimmed
    }

    func fetchBalance(apiKey: String) async throws -> BalanceResponse {
        guard var components = URLComponents(string: baseURL) else {
            throw APIError.networkError("Invalid base URL")
        }
        components.path = components.path.appending("/user/balance")
        guard let url = components.url else { throw APIError.networkError("Invalid base URL") }
        return try await get(url, apiKey: apiKey)
    }

    func fetchUsage(apiKey: String, from start: Date, to end: Date) async throws -> UsageResponse {
        guard var components = URLComponents(string: baseURL) else {
            throw APIError.networkError("Invalid base URL")
        }
        components.path = components.path.appending("/v1/usage")
        components.queryItems = [
            URLQueryItem(name: "start_date", value: Formatters.apiDate.string(from: start)),
            URLQueryItem(name: "end_date", value: Formatters.apiDate.string(from: end))
        ]
        guard let url = components.url else { throw APIError.networkError("Invalid base URL") }
        return try await get(url, apiKey: apiKey)
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ url: URL, apiKey: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError("No HTTP response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw APIError.unauthorized
        case 404:
            // Only /v1/usage is expected to 404, and only per account.
            throw APIError.usageEndpointUnavailable
        case 429:
            throw APIError.rateLimited
        case 500...599:
            throw APIError.serverError(http.statusCode)
        default:
            throw APIError.httpError(http.statusCode)
        }

        let body = data.count > Self.maxBodyBytes ? data.prefix(Self.maxBodyBytes) : data.prefix(data.count)
        do {
            return try JSONDecoder().decode(T.self, from: Data(body))
        } catch {
            throw APIError.decodingError(error.localizedDescription)
        }
    }
}
