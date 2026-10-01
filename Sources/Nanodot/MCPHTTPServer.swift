import Foundation
import Network

/// MCP の Streamable HTTP の最小限の実装。127.0.0.1 だけで待ち受け、POST の JSON-RPC に JSON で答える
final class MCPHTTPServer {
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nanodot.mcp")
    /// メインスレッドで呼ぶ（Editor はメインスレッド専用）
    private let handler: (Data) -> Data?
    var onStatus: ((Status) -> Void)?

    init(handler: @escaping (Data) -> Data?) {
        self.handler = handler
    }

    func start(port: UInt16) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else {
            report(.failed("ポート番号が不正です"))
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // ほかのマシンからは繋がせない
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready: self?.report(.running(port: port))
                case .failed(let e): self?.report(.failed(e.localizedDescription))
                default: break
                }
            }
            listener = l
            report(.starting)
            l.start(queue: queue)
        } catch {
            report(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        report(.stopped)
    }

    private func report(_ s: Status) {
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    // MARK: - 接続

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                self.send(self.respond(req), on: c)
            } else if done || error != nil || buf.count > 32 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func send(_ r: HTTPResponse, on c: NWConnection) {
        c.send(content: r.data, completion: .contentProcessed { _ in c.cancel() })
    }

    private func respond(_ req: HTTPRequest) -> HTTPResponse {
        guard req.path == "/mcp" || req.path == "/" else { return HTTPResponse(status: 404, reason: "Not Found") }
        // ブラウザのページからの DNS リバインディング対策: Origin が付いていたら localhost 以外は断る
        if let origin = req.headers["origin"], !Self.isLocalOrigin(origin) {
            return HTTPResponse(status: 403, reason: "Forbidden", body: Data("Origin not allowed".utf8))
        }
        switch req.method {
        case "POST":
            let out = DispatchQueue.main.sync { handler(req.body) }
            guard let out else { return HTTPResponse(status: 202, reason: "Accepted") }
            return HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: out)
        case "DELETE":
            return HTTPResponse(status: 200, reason: "OK")
        case "GET":
            // サーバーからの通知ストリームは使わない
            return HTTPResponse(status: 405, reason: "Method Not Allowed", extraHeaders: ["Allow": "POST, DELETE"])
        default:
            return HTTPResponse(status: 405, reason: "Method Not Allowed", extraHeaders: ["Allow": "POST, DELETE"])
        }
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return origin == "null" }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// ヘッダーと Content-Length 分の本文がそろっていれば返す
    static func parse(_ d: Data) -> HTTPRequest? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[d.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard d.count - (bodyStart - d.startIndex) >= length else { return nil }
        let path = String(first[1]).split(separator: "?").first.map(String.init) ?? "/"
        return HTTPRequest(method: String(first[0]).uppercased(), path: path, headers: headers,
                           body: Data(d[bodyStart..<(bodyStart + length)]))
    }
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var contentType: String?
    var body = Data()
    var extraHeaders: [String: String] = [:]

    init(status: Int, reason: String, contentType: String? = nil, body: Data = Data(), extraHeaders: [String: String] = [:]) {
        self.status = status
        self.reason = reason
        self.contentType = contentType
        self.body = body
        self.extraHeaders = extraHeaders
    }

    var data: Data {
        var h = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let contentType { h += "Content-Type: \(contentType)\r\n" }
        for (k, v) in extraHeaders { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        return Data(h.utf8) + body
    }
}
