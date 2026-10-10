import Foundation

public struct ProbeResult {
    public let endpoint: URL
    public let statusCode: Int?
    public let message: String
    public let modelIDs: [String]
    public var succeeded: Bool { (200..<300).contains(statusCode ?? 0) }
}

public enum ProviderProbeError: LocalizedError {
    case invalidURL
    case insecureURL
    case missingAPIKey
    case responseTooLarge
    case transport(Error)
    case invalidResponse
    case unsuccessfulResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Base URL 无效"
        case .insecureURL: return "只允许 HTTPS；本机 localhost 可以使用 HTTP"
        case .missingAPIKey: return "请先保存 Secure API Key"
        case .responseTooLarge: return "供应商响应超过安全大小限制"
        case .transport(let error): return "网络请求失败：\(error.localizedDescription)"
        case .invalidResponse: return "供应商返回了无法解析的响应"
        case .unsuccessfulResponse: return "Responses API 返回了失败、未完成或缺少输出的结果"
        }
    }
}

public final class ProviderProbe: NSObject, URLSessionTaskDelegate {
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    public func testModels(profile: ProviderProfile, apiKey: String, completion: @escaping (Result<ProbeResult, Error>) -> Void) {
        request(profile: profile, apiKey: apiKey, endpointName: "models", method: "GET", body: nil, completion: completion)
    }

    public func testResponses(profile: ProviderProfile, apiKey: String, completion: @escaping (Result<ProbeResult, Error>) -> Void) {
        let body: [String: Any] = ["model": profile.model, "input": "Reply with exactly OK.", "max_output_tokens": 16, "stream": false]
        request(profile: profile, apiKey: apiKey, endpointName: "responses", method: "POST", body: try? JSONSerialization.data(withJSONObject: body), completion: completion)
    }

    private func request(profile: ProviderProfile, apiKey: String, endpointName: String, method: String, body: Data?, completion: @escaping (Result<ProbeResult, Error>) -> Void) {
        guard !apiKey.isEmpty else { completion(.failure(ProviderProbeError.missingAPIKey)); return }
        do {
            let endpoint = try makeEndpoint(baseURL: profile.baseURL, endpointName: endpointName)
            var request = URLRequest(url: endpoint)
            request.httpMethod = method
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            request.httpBody = body
            session.dataTask(with: request) { data, response, error in
                let result: Result<ProbeResult, Error>
                if let error = error {
                    result = .failure(ProviderProbeError.transport(error))
                } else if let data = data, data.count > 1_048_576 {
                    result = .failure(ProviderProbeError.responseTooLarge)
                } else if let http = response as? HTTPURLResponse {
                    do {
                        let modelIDs = try Self.validateResponse(data, status: http.statusCode, endpointName: endpointName)
                        let message = Self.message(for: http.statusCode, modelCount: modelIDs.count, endpointName: endpointName)
                        result = .success(ProbeResult(endpoint: endpoint, statusCode: http.statusCode, message: message, modelIDs: modelIDs))
                    } catch { result = .failure(error) }
                } else {
                    result = .failure(ProviderProbeError.invalidResponse)
                }
                DispatchQueue.main.async { completion(result) }
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    public func makeEndpoint(baseURL: String, endpointName: String) throws -> URL {
        guard ["models", "responses"].contains(endpointName) else { throw ProviderProbeError.invalidURL }
        let base = try ProviderProfile.normalizedBaseURL(baseURL)
        guard let url = URL(string: base + "/" + endpointName) else { throw ProviderProbeError.invalidURL }
        return url
    }

    private static func validateResponse(_ data: Data?, status: Int, endpointName: String) throws -> [String] {
        guard (200..<300).contains(status) else { return [] }
        guard let data = data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderProbeError.invalidResponse }
        if endpointName == "models" {
            guard let items = object["data"] as? [[String: Any]],
                  items.allSatisfy({ ($0["id"] as? String)?.isEmpty == false }) else { throw ProviderProbeError.invalidResponse }
            return items.compactMap { $0["id"] as? String }.prefix(200).map { $0 }
        }
        guard (object["id"] as? String)?.isEmpty == false,
              object["status"] as? String == "completed",
              let output = object["output"] as? [[String: Any]], !output.isEmpty,
              object["error"] == nil || object["error"] is NSNull else { throw ProviderProbeError.unsuccessfulResponse }
        return []
    }

    private static func message(for status: Int, modelCount: Int, endpointName: String) -> String {
        switch status {
        case 200..<300:
            return endpointName == "models" ? "HTTP \(status)，找到 \(modelCount) 个模型" : "HTTP \(status)，Responses API 可用"
        case 401, 403: return "HTTP \(status)，API Key 无效或没有权限"
        case 404: return "HTTP 404，供应商不支持此接口或 Base URL 不正确"
        case 429: return "HTTP 429，已触发额度或频率限制"
        default: return "HTTP \(status)，供应商请求失败"
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let oldURL = task.currentRequest?.url, let newURL = request.url,
              oldURL.scheme == newURL.scheme, oldURL.host == newURL.host,
              oldURL.port == newURL.port else {
            completionHandler(nil)
            return
        }
        var sanitized = request
        sanitized.setValue(task.currentRequest?.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        completionHandler(sanitized)
    }
}
