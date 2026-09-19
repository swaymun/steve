import CryptoKit
import Darwin
import Foundation

/// Verified against stripe/link-cli commit 6f486368a762b91f714190db3d4b4d49f5b45ac6.
/// This adapter creates TEST requests only. It cannot retrieve credentials, open
/// approval URLs, approve a purchase, or send payment to a merchant.
struct LinkPurchaseEnvelope: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let name: String
        let quantity: Int
        let unitAmount: Int
    }
    let merchantName: String
    let merchantURL: String
    let items: [Item]
    let shipping: Int
    let tax: Int
    let amount: Int
    let currency: String

    func validate() throws {
        guard Self.safeText(merchantName, maximum: 120),
              let url = URL(string: merchantURL), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              merchantURL.utf8.count <= 500, currency == "usd",
              (1...50_000).contains(amount), (0...50_000).contains(shipping), (0...50_000).contains(tax),
              (1...30).contains(items.count) else { throw LinkTestPaymentError.invalidEnvelope }
        var total = shipping + tax
        for item in items {
            // Upstream's CLI comma-separated line-item parser has no escaping.
            guard Self.safeText(item.name, maximum: 120), !item.name.contains(","),
                  (1...100).contains(item.quantity), (1...50_000).contains(item.unitAmount) else { throw LinkTestPaymentError.invalidEnvelope }
            total += item.quantity * item.unitAmount
        }
        guard total == amount else { throw LinkTestPaymentError.invalidEnvelope }
    }
    func fingerprint() throws -> String {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
    private static func safeText(_ text: String, maximum: Int) -> Bool {
        !text.isEmpty && text == text.trimmingCharacters(in: .whitespacesAndNewlines) && text.utf8.count <= maximum && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Construct this only after the human reviews the exact TEST envelope. The
/// approval does not authorize a live charge or credential release. Root's
/// paired-chat/generation approval gate remains authoritative.
struct LinkTestApproval: Sendable {
    let operationID: UUID
    let envelopeFingerprint: String
    let expiresAt: Date
}

enum LinkTestPaymentError: Error, LocalizedError, Equatable {
    case invalidEnvelope, approvalRequired, changedEnvelope, unavailable, incompatibleCLI, invalidResponse, ambiguous, busy, journal
    var errorDescription: String? {
        switch self {
        case .invalidEnvelope: return "The test purchase needs an exact merchant, USD total, and matching item, shipping, and tax amounts."
        case .approvalRequired: return "Review and approve this exact test purchase before continuing."
        case .changedEnvelope: return "The purchase changed. The previous approval and operation cannot be reused."
        case .unavailable: return "Link CLI is unavailable or the operation failed. Check it locally without sharing its raw output."
        case .incompatibleCLI: return "This Link CLI does not expose the required test and idempotency options. Update it locally before using Steve payments."
        case .invalidResponse: return "Link returned an unsupported response. No payment completion has been confirmed."
        case .ambiguous: return "The test request outcome is uncertain. Inspect the existing operation; never create a replacement automatically."
        case .busy: return "A Link operation is already in progress."
        case .journal: return "The private Link operation journal is unavailable."
        }
    }
}

struct LinkTestRequest: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case created, pending_approval, expired, approved, denied, submitted, succeeded, failed, canceled, requires_action
    }
    let id: String
    /// This is Link's request status, NOT proof of merchant checkout success.
    let status: Status
}

actor LinkTestPayments {
    typealias Runner = @Sendable (_ arguments: [String]) async throws -> SteveProcess.Result
    private struct Entry: Codable {
        let fingerprint: String
        var request: LinkTestRequest?
        var ambiguous: Bool
    }
    private let runner: Runner
    private let journalURL: URL
    private let now: @Sendable () -> Date
    private var inFlight = false
    private var schemaVerified = false

    init(journalURL: URL, now: @escaping @Sendable () -> Date = { Date() }, runner: @escaping Runner) {
        self.journalURL = journalURL
        self.now = now
        self.runner = runner
    }

    /// No npx/download fallback. The local user chooses an already installed
    /// executable. Auth files remain entirely owned by Link CLI.
    static func installed(executable: URL, journalURL: URL) throws -> LinkTestPayments {
        guard executable.isFileURL, executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path) else { throw LinkTestPaymentError.unavailable }
        let environment = safeEnvironment(ProcessInfo.processInfo.environment)
        return LinkTestPayments(journalURL: journalURL) { args in
            try await SteveProcess.run(executable: executable.path, arguments: args, environment: environment, timeout: 15)
        }
    }

    static func safeEnvironment(_ inherited: [String: String]) -> [String: String] {
        // Avoid inherited API/auth/proxy overrides and Node injection flags. The
        // installed CLI resolves its own credentials in the user's normal home.
        var result: [String: String] = [:]
        for key in ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"] { result[key] = inherited[key] }
        result["NO_COLOR"] = "1"
        return result
    }

    func authenticated() async throws -> Bool {
        let data = try await invoke(["auth", "status", "--format", "json"])
        struct Auth: Decodable { let authenticated: Bool }
        guard let result = try? JSONDecoder().decode(Auth.self, from: data) else { throw LinkTestPaymentError.invalidResponse }
        return result.authenticated // Drop token previews, identity and URLs.
    }

    func createTestRequest(_ envelope: LinkPurchaseEnvelope, approval: LinkTestApproval,
                           retryAmbiguous: Bool = false) async throws -> LinkTestRequest {
        let fingerprint = try envelope.fingerprint()
        guard approval.envelopeFingerprint == fingerprint else { throw LinkTestPaymentError.changedEnvelope }
        guard approval.expiresAt > now(), approval.expiresAt.timeIntervalSince(now()) <= 600 else { throw LinkTestPaymentError.approvalRequired }
        guard !inFlight else { throw LinkTestPaymentError.busy }
        inFlight = true; defer { inFlight = false }
        let journalLock = try LinkJournalLock(url: journalURL)
        defer { journalLock.close() }
        var journal = try loadJournal()
        let key = approval.operationID.uuidString.lowercased()
        if let entry = journal[key] {
            guard entry.fingerprint == fingerprint else { throw LinkTestPaymentError.changedEnvelope }
            if let request = entry.request { return request }
            guard !entry.ambiguous || retryAmbiguous else { throw LinkTestPaymentError.ambiguous }
        }
        try await verifySchema()
        try Task.checkCancellation()
        guard approval.expiresAt > now() else { throw LinkTestPaymentError.approvalRequired }
        // Persist BEFORE crossing the process boundary. A crash or timeout must
        // retain the same logical operation and upstream idempotency key.
        journal[key] = Entry(fingerprint: fingerprint, request: nil, ambiguous: true)
        try saveJournal(journal)
        var arguments = ["spend-request", "create", "--format", "json", "--test", "--no-request-approval", "--credential-type", "card", "--idempotency-key", key,
                         "--merchant-name", envelope.merchantName, "--merchant-url", envelope.merchantURL,
                         "--amount", String(envelope.amount), "--currency", envelope.currency,
                         "--context", "The user reviewed this exact test purchase in Steve. This is an integration test request only; it does not authorize a real purchase or release payment credentials."]
        for item in envelope.items {
            arguments += ["--line-item", "name:\(item.name),unit_amount:\(item.unitAmount),quantity:\(item.quantity)"]
        }
        arguments += ["--total", "type:shipping,display_text:Shipping,amount:\(envelope.shipping)",
                      "--total", "type:tax,display_text:Tax,amount:\(envelope.tax)",
                      "--total", "type:total,display_text:Total,amount:\(envelope.amount)"]
        do {
            let data = try await invoke(arguments)
            let request = try Self.decodeRequest(data)
            journal[key]?.request = request
            journal[key]?.ambiguous = false
            try saveJournal(journal)
            return request
        } catch { throw LinkTestPaymentError.ambiguous }
    }

    func retrieveTestRequest(operationID: UUID) async throws -> LinkTestRequest {
        guard !inFlight else { throw LinkTestPaymentError.busy }
        inFlight = true; defer { inFlight = false }
        let journalLock = try LinkJournalLock(url: journalURL)
        defer { journalLock.close() }
        let journal = try loadJournal()
        guard let entry = journal[operationID.uuidString.lowercased()], let known = entry.request else { throw LinkTestPaymentError.ambiguous }
        // Never --include card/link_pay_token; no arbitrary ID can be imported.
        let data = try await invoke(["spend-request", "retrieve", known.id, "--format", "json"])
        let request = try Self.decodeRequest(data)
        guard request.id == known.id else { throw LinkTestPaymentError.invalidResponse }
        return request
    }

    private func verifySchema() async throws {
        guard !schemaVerified else { return }
        let data = try await invoke(["spend-request", "create", "--schema", "--format", "json"])
        // Incur schemas vary in outer layout; inspect keys structurally, never
        // execute schema descriptions or returned continuation commands.
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw LinkTestPaymentError.incompatibleCLI }
        func keys(_ value: Any) -> Set<String> {
            if let object = value as? [String: Any] { return Set(object.keys).union(object.values.reduce(into: Set<String>()) { $0.formUnion(keys($1)) }) }
            if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
            return []
        }
        let names = keys(value)
        guard names.contains("test"), names.contains("idempotencyKey"), names.contains("requestApproval") else { throw LinkTestPaymentError.incompatibleCLI }
        schemaVerified = true
    }

    private func invoke(_ arguments: [String]) async throws -> Data {
        do {
            let result = try await runner(arguments)
            guard result.code == 0, result.output.count <= 262_144 else { throw LinkTestPaymentError.unavailable }
            return result.output
        } catch { throw LinkTestPaymentError.unavailable }
    }
    private static func decodeRequest(_ data: Data) throws -> LinkTestRequest {
        guard let request = try? JSONDecoder().decode(LinkTestRequest.self, from: data), request.id.hasPrefix("lsrq_"),
              request.id.utf8.count <= 100, request.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { throw LinkTestPaymentError.invalidResponse }
        return request
    }
    private func loadJournal() throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [:] }
        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 1_048_576 else { throw LinkTestPaymentError.journal }
        guard let journal = try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: journalURL)) else { throw LinkTestPaymentError.journal }
        return journal
    }
    private func saveJournal(_ journal: [String: Entry]) throws {
        guard journal.count <= 1000 else { throw LinkTestPaymentError.journal }
        try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
}

/// Held across await to prevent two app instances replaying an unknown operation.
private final class LinkJournalLock {
    private var descriptor: Int32
    init(url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent == parent.resolvingSymlinksInPath(), FileManager.default.fileExists(atPath: parent.path) else { throw LinkTestPaymentError.journal }
        descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LinkTestPaymentError.journal }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); descriptor = -1; throw LinkTestPaymentError.busy }
    }
    func close() { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
