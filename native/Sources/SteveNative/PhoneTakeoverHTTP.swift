import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

struct PhoneTakeoverOrigin: Sendable, Equatable {
    let value: String
    let host: String
    let authority: String
    init(_ raw: String) throws {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port == nil || [443, 8443, 10000].contains(url.port!),
              !host.isEmpty, host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { throw PhoneTakeoverError.origin }
        self.host = host
        authority = host + ((url.port == nil || url.port == 443) ? "" : ":\(url.port!)")
        value = "https://" + authority
    }
}

struct PhoneHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: [String]]
    let body: Data
    func header(_ name: String) -> String? {
        guard let values = headers[name.lowercased()], values.count == 1 else { return nil }
        return values[0]
    }
}

struct PhoneHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data
}

/// The only HTTP operations are session management, a current JPEG, and bounded
/// pointer/keyboard input. No path, command, file, model, or shell endpoint exists.
final class PhoneTakeoverHTTPService: Sendable {
    static let cookieName = "__Host-steve_takeover"
    let origin: PhoneTakeoverOrigin
    let session: PhoneTakeoverSession
    private let assets: [String: (String, Data)]

    init(origin: PhoneTakeoverOrigin, session: PhoneTakeoverSession, assets: [String: (String, Data)]? = nil) throws {
        self.origin = origin
        self.session = session
        if let assets { self.assets = assets }
        else {
            var loaded: [String: (String, Data)] = [:]
            for (path, ext, type) in [("/", "html", "text/html; charset=utf-8"), ("/steve-phone.css", "css", "text/css; charset=utf-8"), ("/steve-phone.js", "js", "text/javascript; charset=utf-8")] {
                guard let file = Bundle.module.url(forResource: "steve-phone", withExtension: ext, subdirectory: "PhoneTakeover") ?? Bundle.module.url(forResource: "steve-phone", withExtension: ext) else { throw PhoneTakeoverError.unavailable("Phone controls are missing from this app bundle.") }
                loaded[path] = (type, try Data(contentsOf: file))
            }
            self.assets = loaded
        }
    }

    func pairingURL(boundary: PhoneAccessBoundary) async throws -> URL {
        let token = try await session.issuePairingToken(boundary: boundary)
        // The fragment never reaches the HTTP server or proxy request logs.
        return URL(string: origin.value + "/#pair=" + token)!
    }

    func handle(_ request: PhoneHTTPRequest) async -> PhoneHTTPResponse {
        do {
            guard request.body.count <= 8192, request.path.count <= 128,
                  request.header("host") == origin.authority,
                  request.headers.count <= 32 else { throw PhoneTakeoverError.origin }
            if let requestedOrigin = request.headers["origin"] {
                guard requestedOrigin.count == 1, requestedOrigin[0] == origin.value else { throw PhoneTakeoverError.origin }
            }
            if request.method == "GET", let asset = assets[request.path] {
                return secured(PhoneHTTPResponse(status: 200, headers: ["Content-Type": asset.0], body: asset.1))
            }
            guard request.method == "POST", request.header("origin") == origin.value,
                  request.header("content-type") == "application/json" else { throw PhoneTakeoverError.origin }
            switch request.path {
            case "/api/pair":
                struct Pair: Decodable { let token: String }
                let token = try JSONDecoder().decode(Pair.self, from: request.body).token
                let grant = try await session.claim(token: token)
                var response = json(["state": "active", "csrf": grant.csrf, "expiresAt": ISO8601DateFormatter().string(from: grant.expiresAt)])
                response.headers["Set-Cookie"] = "\(Self.cookieName)=\(grant.cookie); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=900"
                return secured(response)
            case "/api/heartbeat", "/api/frame", "/api/input", "/api/finish":
                guard let cookie = Self.cookie(in: request.header("cookie")), let csrf = request.header("x-steve-csrf") else { throw PhoneTakeoverError.unauthorized }
                switch request.path {
                case "/api/heartbeat":
                    try await session.heartbeat(cookie: cookie, csrf: csrf)
                    return secured(json(["state": "active"]))
                case "/api/frame":
                    let frame = try await session.frame(cookie: cookie, csrf: csrf)
                    return secured(PhoneHTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg", "X-Steve-Frame": frame.id], body: frame.jpeg))
                case "/api/input":
                    let input = try JSONDecoder().decode(PhoneTakeoverInput.self, from: request.body)
                    try await session.input(input, cookie: cookie, csrf: csrf)
                    return secured(json(["state": "active", "sequence": String(input.sequence)]))
                default:
                    struct Finish: Decodable { let resume: Bool }
                    let resume = try JSONDecoder().decode(Finish.self, from: request.body).resume
                    try await session.finish(cookie: cookie, csrf: csrf, resume: resume)
                    var response = json(["state": "ended", "summary": resume ? "Control ended. Steve can process queued requests. Send a new message to continue an interrupted task." : "Disconnected. Steve remains paused."])
                    response.headers["Set-Cookie"] = "\(Self.cookieName)=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"
                    return secured(response)
                }
            default: return secured(json(["error": "Not found."], status: 404))
            }
        } catch let error as PhoneTakeoverError {
            let status: Int
            switch error {
            case .unauthorized, .expired: status = 401
            case .origin: status = 403
            case .busy, .staleFrame: status = 409
            case .invalidInput: status = 400
            case .unavailable: status = 503
            }
            return secured(json(["error": error.localizedDescription], status: status))
        } catch {
            // Native provider errors and malformed input never get echoed back.
            return secured(json(["error": "Control could not continue. Steve remains paused; reconnect from the Mac."], status: 400))
        }
    }

    private func json(_ body: [String: String], status: Int = 200) -> PhoneHTTPResponse {
        PhoneHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONEncoder().encode(body)) ?? Data())
    }

    private func secured(_ response: PhoneHTTPResponse) -> PhoneHTTPResponse {
        var response = response
        response.headers["Cache-Control"] = "no-store, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        return response
    }

    private static func cookie(in header: String?) -> String? {
        let values = (header ?? "").split(separator: ";").compactMap { component -> String? in
            let pair = component.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == cookieName else { return nil }
            return String(pair[1])
        }
        return values.count == 1 ? values[0] : nil
    }
}

final class PhoneTakeoverHTTPServer: @unchecked Sendable {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let service: PhoneTakeoverHTTPService

    init(service: PhoneTakeoverHTTPService, port: Int = 0) async throws {
        self.service = service
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: .seconds(10)))
                            try channel.pipeline.syncOperations.addHandler(PhoneHTTPHandler(service: service))
                        }
                    }
                }
                .bind(host: "127.0.0.1", port: port).get()
            self.port = channel.localAddress?.port ?? port
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        await service.session.revoke()
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

private final class PhoneHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let service: PhoneTakeoverHTTPService
    private var head: HTTPRequestHead?
    private var body = Data()
    private var pending: Task<Void, Never>?
    private var responded = false

    init(service: PhoneTakeoverHTTPService) { self.service = service }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { context.close(promise: nil); return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard self.head == nil, pending == nil, head.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 8192 else { context.close(promise: nil); return }
            self.head = head
        case .body(var buffer):
            guard body.count + buffer.readableBytes <= 8192 else { context.close(promise: nil); return }
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard let head, pending == nil else { context.close(promise: nil); return }
            var headers: [String: [String]] = [:]
            for header in head.headers { headers[header.name.lowercased(), default: []].append(header.value) }
            let request = PhoneHTTPRequest(method: head.method.rawValue, path: head.uri, headers: headers, body: body)
            self.head = nil
            body = Data()
            let bound = NIOLoopBound((context, self), eventLoop: context.eventLoop)
            pending = Task { [service] in
                let response = await service.handle(request)
                guard !Task.isCancelled else { return }
                bound.eventLoop.execute {
                    let (context, handler) = bound.value
                    handler.pending = nil
                    handler.responded = true
                    var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
                    headers.add(name: "Content-Length", value: String(response.body.count))
                    headers.add(name: "Connection", value: "close")
                    let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers)
                    context.write(handler.wrapOutboundOut(.head(head)), promise: nil)
                    var buffer = context.channel.allocator.buffer(capacity: response.body.count)
                    buffer.writeBytes(response.body)
                    context.write(handler.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    context.writeAndFlush(handler.wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pending?.cancel()
        pending = nil
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
}
