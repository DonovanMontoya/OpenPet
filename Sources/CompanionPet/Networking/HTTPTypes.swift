import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    var body: Data

    func headerValue(for name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data?
    var streamingBody: AsyncStream<Data>?

    init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil, streamingBody: AsyncStream<Data>? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.streamingBody = streamingBody
    }

    static func json(statusCode: Int, payload: [String: String]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        return HTTPResponse(
            statusCode: statusCode,
            headers: [
                "content-type": "application/json; charset=utf-8",
            ],
            body: data
        )
    }
}

enum HTTPServerError: Error, LocalizedError {
    case invalidRequestLine
    case invalidRequestEncoding
    case listenerUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRequestLine:
            return "The HTTP request line could not be parsed."
        case .invalidRequestEncoding:
            return "The HTTP request used an unsupported encoding."
        case .listenerUnavailable:
            return "The local proxy listener could not be started."
        }
    }
}

enum HTTPStatus {
    static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 201:
            return "Created"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 403:
            return "Forbidden"
        case 404:
            return "Not Found"
        case 405:
            return "Method Not Allowed"
        case 408:
            return "Request Timeout"
        case 500:
            return "Internal Server Error"
        case 502:
            return "Bad Gateway"
        case 503:
            return "Service Unavailable"
        default:
            return HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
        }
    }
}
