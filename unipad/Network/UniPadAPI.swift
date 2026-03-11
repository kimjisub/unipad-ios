import Foundation
import os.log

// MARK: - API Models

struct UnishareVO: Codable, Sendable {
    let id: String?
    let title: String?
    let producer: String?
    let content: String?
    let website: String?
    let youtube: String?
    let fileSize: Int64
    let isPublic: Bool
    let password: String?
    let downloadCount: Int

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case title, producer, content, website, youtube
        case fileSize, isPublic, password, downloadCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        producer = try container.decodeIfPresent(String.self, forKey: .producer)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        website = try container.decodeIfPresent(String.self, forKey: .website)
        youtube = try container.decodeIfPresent(String.self, forKey: .youtube)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        password = try container.decodeIfPresent(String.self, forKey: .password)
        downloadCount = try container.decodeIfPresent(Int.self, forKey: .downloadCount) ?? 0
    }
}

// MARK: - UniPad API

final class UniPadAPI: Sendable {
    static let shared = UniPadAPI()

    private let baseURL = "https://api.unipad.io"
    private let logger = Logger(subsystem: "com.kimjisub.unipad", category: "API")
    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
    }

    // MARK: - Unishare

    func getUnishare(code: String) async throws -> UnishareVO {
        let url = URL(string: "\(baseURL)/unishare/\(code)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(UnishareVO.self, from: data)
    }

    // MARK: - File Download

    func downloadFile(from urlString: String) async throws -> (URL, URLResponse) {
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }
        return try await session.download(from: url)
    }

}

// MARK: - Error Types

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingFailed
    case networkError(Error)

    var isNotFound: Bool {
        if case .httpError(let code) = self { return code == 404 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid server response"
        case .httpError(let code): return "HTTP error \(code)"
        case .decodingFailed: return "Failed to decode response"
        case .networkError(let error): return error.localizedDescription
        }
    }
}

