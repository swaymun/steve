import AppKit
import CoreImage
import Foundation
import ServiceManagement
import SwiftUI

struct RPCError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum SteveLog {
    private static let lock = NSLock()
    private static let formatter = ISO8601DateFormatter()
    static var fileURL: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Steve", isDirectory: true).appendingPathComponent("steve.log") }
    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) { FileManager.default.createFile(atPath: fileURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: fileURL); handle.seekToEndOfFile(); handle.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8)); try? handle.close()
        } catch {}
    }
    static func open() { write("Opening diagnostics"); NSWorkspace.shared.open(fileURL) }
}

enum SteveBrowser { static func open(_ url: URL) { let opened = NSWorkspace.shared.open(url); SteveLog.write("Browser handoff opened=\(opened) scheme=\(url.scheme ?? "unknown")") } }

struct Settings: Codable, Sendable {
    var displayName: String
    var model: String
    var effort: String
    var defaultPermission: String = "workspace-write"
    var permissionProfile: String?
    var workspaceRoot: String?
    var shellNetworkEnabled: Bool = true
    var burstWindowMs: UInt64 = 1500
    var timezone: String = "UTC"
    var serviceTier: SteveServiceTier = .standard
}
enum SteveServiceTier: String, Codable, CaseIterable, Sendable {
    case standard, fast
    var wireValue: String { self == .fast ? "fast" : "default" }
    var resolvedValue: String { self == .fast ? "priority" : "default" }
}

extension Settings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        model = try c.decode(String.self, forKey: .model)
        effort = try c.decode(String.self, forKey: .effort)
        defaultPermission = try c.decodeIfPresent(String.self, forKey: .defaultPermission) ?? "workspace-write"
        permissionProfile = try c.decodeIfPresent(String.self, forKey: .permissionProfile)
        workspaceRoot = try c.decodeIfPresent(String.self, forKey: .workspaceRoot)
        shellNetworkEnabled = try c.decodeIfPresent(Bool.self, forKey: .shellNetworkEnabled) ?? true
        burstWindowMs = try c.decodeIfPresent(UInt64.self, forKey: .burstWindowMs) ?? 1500
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC"
        serviceTier = try c.decodeIfPresent(SteveServiceTier.self, forKey: .serviceTier) ?? .standard
    }
}
struct Status: Codable, Sendable { let state: String; let detail: String; let connected: Bool }
struct ModelEntry: Codable, Identifiable, Sendable { let id: String; let model: String?; let displayName: String?; let description: String?; let supportedReasoningEfforts: [ReasoningEffort]; let isDefault: Bool? }
struct ReasoningEffort: Codable, Sendable { let reasoningEffort: String; let description: String? }
struct PermissionProfile: Codable, Identifiable, Sendable { let id: String; let name: String?; let description: String?; let allowed: Bool }
struct Account: Codable, Sendable { let type: String?; let email: String?; let planType: String?; let id: String? }
struct AccountSnapshot: Codable, Sendable { let account: Account?; let requiresOpenaiAuth: Bool }
struct RateWindow: Codable, Sendable { let usedPercent: Double; let windowDurationMins: UInt64?; let resetsAt: Double? }
struct Usage: Codable, Sendable { let primary: RateWindow?; let secondary: RateWindow? }
struct TrustedConversation: Codable, Sendable { let chatGuid: String; let senderHandle: String }
struct ReceiveAddress: Codable, Identifiable, Sendable { let address: String; let label: String?; var id: String { address } }
struct PairingChallenge: Codable, Sendable {
    let code: String; let expiresAtMs: UInt64; let receiveAddress: String; let uri: String; let messageURI: String
    enum CodingKeys: String, CodingKey { case code, expiresAtMs, receiveAddress, uri; case messageURI = "messageUri" }
    init(code: String, expiresAtMs: UInt64, receiveAddress: String, uri: String, messageURI: String = "") { self.code = code; self.expiresAtMs = expiresAtMs; self.receiveAddress = receiveAddress; self.uri = uri; self.messageURI = messageURI }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        expiresAtMs = try container.decode(UInt64.self, forKey: .expiresAtMs)
        receiveAddress = try container.decode(String.self, forKey: .receiveAddress)
        uri = try container.decode(String.self, forKey: .uri)
        messageURI = try container.decodeIfPresent(String.self, forKey: .messageURI) ?? ""
    }
}
struct Snapshot: Codable, Sendable { let status: Status; let settings: Settings; let paused: Bool; let dependencies: [Dependency]; let transportMode: String; let account: AccountSnapshot?; let models: [ModelEntry]; let permissions: [PermissionProfile]; let usage: Usage?; let trustedConversation: TrustedConversation?; let pairing: PairingChallenge? }
struct Dependency: Codable, Sendable { let name: String; let available: Bool; let detail: String }
struct UsageRow: Identifiable, Sendable { let id: String; let title: String; let subtitle: String }
struct LoginSnapshot: Codable, Sendable { let loginID: String?; let authURL: String?; enum CodingKeys: String, CodingKey { case loginID = "loginId"; case authURL = "authUrl" } }
struct PairingSnapshot: Codable, Sendable { let addresses: [ReceiveAddress]; let challenge: PairingChallenge?; let trustedConversation: TrustedConversation?; let icloudAccount: String?; let messagesError: String? }

@MainActor
final class SteveModel: ObservableObject {
    static weak var active: SteveModel?
    @Published var snapshot: Snapshot?
    @Published var message = "Checking Codex sign-in…"
    @Published var loginURL: URL?
    @Published var requiresLogin = false
    @Published var phoneOpen = false
    @Published var addresses: [ReceiveAddress] = []
    @Published var icloudAccount = ""
    @Published var pairing: PairingChallenge?
    @Published var pendingApproval: PendingApprovalSnapshot?
    @Published var phoneAccessURL: URL?
    private let runtime: SteveRuntime?
    private var phoneAccess: StevePhoneAccess?
    private var taskVideo: SteveTaskVideoControl?
    private var localControl: SteveLocalControlServer?
    private var pairingMonitor: Task<Void, Never>?

    init() {
        runtime = try? SteveRuntime()
        Self.active = self
        Task { [weak self] in
            guard let self, let runtime = self.runtime else { return }
            do {
                let taskVideo = SteveTaskVideoControl(runtime: runtime)
                self.taskVideo = taskVideo
                self.phoneAccess = StevePhoneAccess(runtime: runtime, beforeTakeover: { await taskVideo.cancel() })
                await runtime.setPhoneAccessHandler { [weak self] in
                    guard let phone = await self?.phoneAccess else { throw PhoneTakeoverError.unavailable("Phone access is unavailable.") }
                    return try await phone.pairingURL()
                }
                self.localControl = try SteveLocalControlServer { [weak self] request in
                    guard let self else { return SteveControlResponse(state: "failed", summary: "Steve is shutting down.") }
                    return await self.handleControl(request, runtime: runtime)
                }
                await runtime.start(); await self.updateSnapshot(from: runtime)
                do { try await self.phoneAccess?.restore() } catch { self.message = error.localizedDescription }
            } catch { self.message = error.localizedDescription }
        }
    }
    func shutdown() async {
        pairingMonitor?.cancel()
        await taskVideo?.cancel()
        await phoneAccess?.stop()
        await runtime?.stop()
        localControl = nil
    }
    func sync() async { if let runtime { await updateSnapshot(from: runtime) } }
    private func handleControl(_ request: SteveControlRequest, runtime: SteveRuntime) async -> SteveControlResponse {
        if request.command == "video", let taskVideo { return await taskVideo.handle(request) }
        if request.command == "phone" {
            do {
                guard let phoneAccess, Set(request.options.keys).isSubset(of: ["disconnect"]) else { throw RPCError(message: "Phone access is unavailable or the command is invalid.") }
                if request.options["disconnect"] == "true" {
                    await phoneAccess.revoke()
                    phoneAccessURL = nil
                    return SteveControlResponse(state: "ready", summary: "Phone control ended. Steve remains paused.")
                }
                let url = try await phoneAccess.pairingURL()
                return SteveControlResponse(state: "needs_user_action", summary: "Open this private one-time link in iPhone Safari with Tailscale connected. It expires in two minutes. Treat the link as a password.", values: ["phoneURL": url.absoluteString])
            } catch { return SteveControlResponse(state: "needs_user_action", summary: error.localizedDescription) }
        }
        let response = await SteveControl.handle(request, runtime: runtime)
        guard request.command == "setup", request.options["phone-access"] == "true", response.state != "failed" else { return response }
        do {
            guard let phoneAccess else { throw RPCError(message: "Phone access is not ready.") }
            let origin = try await phoneAccess.configure()
            var values = response.values
            values["phoneOrigin"] = origin
            values["nextStep"] = "Run steve phone to get a one-time Safari link. Steve needs Screen Recording and Accessibility for takeover."
            return SteveControlResponse(state: response.state, summary: "Private phone access configured. " + response.summary, checks: response.checks, values: values)
        } catch {
            return SteveControlResponse(state: "needs_user_action", summary: error.localizedDescription, checks: response.checks, values: response.values)
        }
    }
    func preparePhoneAccess() {
        Task { [weak self] in
            guard let self, let phoneAccess = self.phoneAccess else { return }
            do {
                _ = try await phoneAccess.configure()
                self.phoneAccessURL = try await phoneAccess.pairingURL()
                self.message = "Scan this one-time link in iPhone Safari. Connect Tailscale on both devices."
            } catch { self.message = error.localizedDescription }
        }
    }
    func resolveApproval(_ decision: CodexApprovalDecision) {
        guard let pendingApproval else { return }
        run { try await $0.resolveApproval(id: pendingApproval.id, decision: decision) }
    }
    func openConnectionSetup() {
        guard let pendingApproval, pendingApproval.requiresConnectionSetup else { return }
        run { runtime in
            try await runtime.openConnectionSetup(id: pendingApproval.id) { NSWorkspace.shared.open($0) }
        }
    }
    var configured: Bool { snapshot?.status.connected == true && snapshot?.settings.workspaceRoot != nil && snapshot?.settings.permissionProfile != nil }
    var codexUnavailable: Bool { snapshot?.dependencies.first(where: { $0.name == "codex" })?.available == false }
    var canPhone: Bool { configured }
    var usageRows: [UsageRow] {
        guard let usage = snapshot?.usage else { return [] }; let windows = [usage.primary, usage.secondary].compactMap { $0 }
        return windows.enumerated().map { index, window in
            let title: String
            if windows.count == 1 { title = "Weekly Codex Usage" } else if let duration = window.windowDurationMins { title = duration <= 300 ? "Five-hour Codex Usage" : "Weekly Codex Usage" } else { title = index == 0 ? "Five-hour Codex Usage" : "Weekly Codex Usage" }
            return UsageRow(id: "\(title)-\(index)", title: title, subtitle: usageSubtitle(for: window))
        }
    }
    func refresh() {
        guard let runtime else { return }
        Task { [weak self] in do { try await runtime.refresh(); await self?.updateSnapshot(from: runtime) } catch { await MainActor.run { self?.message = error.localizedDescription } } }
    }
    func login() {
        guard let runtime else { return }
        Task { [weak self] in
            do {
                let login = try await runtime.loginStart()
                if let value = login.authURL, let url = URL(string: value) {
                    await MainActor.run { self?.loginURL = url; self?.message = "Finish signing in in your browser."; SteveBrowser.open(url) }
                    for _ in 0..<90 { try? await Task.sleep(for: .seconds(2)); try? await runtime.refresh(); if (await runtime.snapshot()).account?.account != nil { break } }
                    await self?.updateSnapshot(from: runtime)
                } else { await MainActor.run { self?.message = "Sign-in is not ready yet. Try again." } }
            } catch { await MainActor.run { self?.message = error.localizedDescription } }
        }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.title = "Choose Steve workspace"
        guard panel.runModal() == .OK, let path = panel.url?.path, let runtime else { return }
        Task { [weak self] in do { try await runtime.configureWorkspace(path); await MainActor.run { self?.message = "Workspace saved." }; await self?.updateSnapshot(from: runtime) } catch { await MainActor.run { self?.message = error.localizedDescription } } }
    }
    func selectPermission(_ value: String) { run { try await $0.selectPermission(value) } }
    func selectModel(_ value: String) { run { try await $0.selectModel(value) } }
    func selectServiceTier(_ value: SteveServiceTier) { run { try await $0.selectServiceTier(value.rawValue) } }
    func selectEffort(_ value: String) { run { try await $0.selectEffort(value) } }
    func togglePause() { let value = snapshot?.paused != true; run { try await $0.setPaused(value) } }
    func startPhonePairing() {
        guard let runtime else { return }; message = "Preparing phone pairing…"
        Task { [weak self] in do { let result = try await runtime.createPairing(); await MainActor.run { self?.addresses = result.addresses; self?.icloudAccount = result.icloudAccount ?? ""; self?.pairing = result.challenge; self?.phoneOpen = true; self?.message = "Scan to open Messages, then send the one-time code below."; self?.monitorPairing() } } catch { await MainActor.run { self?.message = error.localizedDescription } } }
    }
    func disconnectPhone() {
        guard let runtime else { return }
        pairingMonitor?.cancel()
        phoneAccessURL = nil
        Task { [weak self] in
            guard let self else { return }
            await self.phoneAccess?.revoke()
            do {
                try await runtime.disconnectPhone()
                self.pairing = nil
                self.message = "Phone disconnected."
                await self.updateSnapshot(from: runtime)
            } catch { self.message = error.localizedDescription }
        }
    }
    func closePhonePairing() { pairingMonitor?.cancel(); phoneOpen = false }
    private func monitorPairing() {
        pairingMonitor?.cancel(); guard let runtime else { return }
        pairingMonitor = Task { [weak self] in
            while !Task.isCancelled { await self?.updateSnapshot(from: runtime); if (await runtime.snapshot()).trustedConversation != nil { await MainActor.run { self?.pairing = nil; self?.phoneOpen = false; self?.message = "Phone connected." }; return }; try? await Task.sleep(for: .seconds(1.5)) }
        }
    }
    func openPairingMessage() { guard let pairing, let url = URL(string: pairing.messageURI.isEmpty ? pairing.uri : pairing.messageURI) else { message = "Copy the pairing code into Messages."; return }; NSWorkspace.shared.open(url) }
    func copyPairingCode() { guard let pairing else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pairing.code, forType: .string); message = "Pairing code copied." }
    func openDiagnostics() { SteveLog.open(); message = "Diagnostics opened." }
    func openFullDiskAccessSettings() { for raw in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles", "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"] where NSWorkspace.shared.open(URL(string: raw)!) { message = "Add Steve under Full Disk Access, then relaunch Steve."; return }; message = "Open System Settings → Privacy & Security → Full Disk Access." }
    func openLoginPage() { if let loginURL { SteveBrowser.open(loginURL) } else { message = "Sign-in is not ready yet." } }
    private func run(_ operation: @escaping (SteveRuntime) async throws -> Void) { guard let runtime else { return }; Task { [weak self] in do { try await operation(runtime); try await runtime.refresh(); await self?.updateSnapshot(from: runtime) } catch { await MainActor.run { self?.message = error.localizedDescription } } } }
    private func updateSnapshot(from runtime: SteveRuntime) async { let value = await runtime.snapshot(); snapshot = value; pendingApproval = await runtime.pendingApproval(); pairing = value.pairing; requiresLogin = value.account?.account == nil; if codexUnavailable { message = value.status.detail.isEmpty ? "Codex is unavailable." : value.status.detail } else if requiresLogin { message = "Sign in to Codex to continue." } else if message == "Checking Codex sign-in…" { message = "" } }
}

struct StevePopover: View {
    @ObservedObject var model: SteveModel
    @State private var tierExpanded = false
    @State private var permissionsExpanded = false; @State private var modelsExpanded = false; @State private var effortsExpanded = false; @State private var advancedExpanded = false; @State private var phoneExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { SteveLogo().frame(width: 30, height: 30); Text("Steve").bold(); Spacer() }.padding(.bottom, 10)
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(model.codexUnavailable ? .red : .secondary).padding(.vertical, 10) }
            Divider()
            if model.codexUnavailable { Text("Steve is paused because Codex is unavailable.").font(.caption).foregroundStyle(.red).padding(.vertical, 8) }
            else if model.requiresLogin { action("Sign in", prominent: true, action: model.login); if model.loginURL != nil { Button("Open sign-in page", action: model.openLoginPage).buttonStyle(.plain).font(.caption).padding(.horizontal, 8) } }
            else {
                action("Workspace", subtitle: model.snapshot?.settings.workspaceRoot ?? "Not assigned", action: model.chooseWorkspace); Divider()
                disclosure("Permissions", value: model.snapshot?.settings.permissionProfile.map(humanizeLabel) ?? "Select a profile", expanded: $permissionsExpanded) { ForEach(model.snapshot?.permissions ?? []) { profile in action(humanizeLabel(profile.name ?? profile.id), subtitle: profile.id.trimmingCharacters(in: CharacterSet(charactersIn: ":")) == "danger-full-access" ? permissionDescription(profile.id) : (profile.description ?? permissionDescription(profile.id)), disabled: !profile.allowed) { model.selectPermission(profile.id) } } }
                disclosure("Default Model", value: humanizeModelLabel(model.snapshot?.settings.model ?? "Not loaded"), expanded: $modelsExpanded) { ForEach(model.snapshot?.models ?? []) { entry in action(humanizeModelLabel(entry.displayName ?? entry.id), subtitle: entry.description ?? modelDescription(entry.id)) { model.selectModel(entry.id) } } }
                let selected = model.snapshot?.models.first(where: { $0.id == model.snapshot?.settings.model })
                disclosure("Reasoning Effort", value: humanizeLabel(model.snapshot?.settings.effort ?? "Not loaded"), expanded: $effortsExpanded) { ForEach(selected?.supportedReasoningEfforts ?? [], id: \.reasoningEffort) { effort in action(humanizeLabel(effort.reasoningEffort), subtitle: effort.description ?? reasoningDescription(effort.reasoningEffort)) { model.selectEffort(effort.reasoningEffort) } } }
                disclosure("Service Tier", value: humanizeLabel(model.snapshot?.settings.serviceTier.rawValue ?? "standard"), expanded: $tierExpanded) { ForEach(SteveServiceTier.allCases, id: \.self) { tier in action(humanizeLabel(tier.rawValue), subtitle: tier == .fast ? "Faster responses; higher usage where available." : "Standard processing.") { model.selectServiceTier(tier) } } }
                ForEach(model.usageRows) { row in infoRow(row.title, subtitle: row.subtitle) }; Divider()
                if let phone = model.snapshot?.trustedConversation { DisclosureGroup(isExpanded: $phoneExpanded) { action("Control Chrome from iPhone", action: model.preparePhoneAccess); action("Disconnect Phone", action: model.disconnectPhone) } label: { HStack { Text("Phone connected:"); Spacer(); Text(phoneDisplay(phone.senderHandle)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }.padding(.vertical, 5) } else { action("Connect Phone", disabled: !model.canPhone, action: model.startPhonePairing) }
                if let url = model.phoneAccessURL {
                    Text("Scan in iPhone Safari within two minutes").font(.caption)
                    QRCodeView(value: url.absoluteString).frame(width: 160, height: 160).accessibilityLabel("One-time private phone control link")
                    Button("Hide link") { model.phoneAccessURL = nil }.font(.caption)
                }
                action(model.snapshot?.paused == true ? "Resume Steve" : "Pause Steve", disabled: !model.configured, action: model.togglePause)
            }
            if let approval = model.pendingApproval {
                Divider()
                Text(approval.requiresConnectionSetup ? "Connection setup required" : "Approval requested").font(.headline).padding(.top, 8)
                if let host = approval.originHost { Text(host).font(.caption).foregroundStyle(.secondary) }
                Text(approval.message).font(.caption).textSelection(.enabled).padding(.vertical, 5)
                HStack {
                    if approval.requiresConnectionSetup {
                        Button("Open reconnection") { model.openConnectionSetup() }
                        Button("Dismiss") { model.resolveApproval(.cancel) }
                    } else {
                        Button("Allow once") { model.resolveApproval(.accept) }
                        Button("Decline") { model.resolveApproval(.decline) }
                    }
                }.padding(.bottom, 8)
            }
            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) { action("Full Disk Access", action: model.openFullDiskAccessSettings); action("Diagnostics", action: model.openDiagnostics) }
            Button("Quit Steve") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.red).padding(8)
        }.padding(14).frame(width: 390).background(Color(nsColor: .windowBackgroundColor)).sheet(isPresented: $model.phoneOpen) { PhoneView(model: model) }.task {
            model.refresh()
            while !Task.isCancelled {
                await model.sync()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
    private func action(_ title: String, subtitle: String? = nil, prominent: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View { Button(action: action) { HStack { VStack(alignment: .leading, spacing: 2) { Text(title); if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) } }; Spacer() } }.buttonStyle(.plain).foregroundStyle(prominent ? Color.green : Color.primary).disabled(disabled).padding(.vertical, 7).padding(.horizontal, 7) }
    private func disclosure(_ title: String, value: String, expanded: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View { DisclosureGroup(isExpanded: expanded) { content().padding(.leading, 10) } label: { HStack { Text(title); Spacer(); Text(value).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }.padding(.vertical, 5).padding(.horizontal, 7) }
    private func infoRow(_ title: String, subtitle: String) -> some View { HStack { VStack(alignment: .leading, spacing: 2) { Text(title); Text(subtitle).font(.caption2).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, 7).padding(.horizontal, 7) }
}

struct SteveLogo: View { var body: some View { Image(nsImage: SteveLogoSource.image() ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32, height: 32))).resizable().aspectRatio(contentMode: .fit) } }
private enum SteveLogoSource {
    static func image() -> NSImage? { Bundle.module.url(forResource: "SteveLogo", withExtension: "png").flatMap(NSImage.init(contentsOf:)) }
    static func statusBarImage() -> NSImage? { guard let source = image() else { return nil }; let result = NSImage(size: NSSize(width: 18, height: 18)); result.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .high; let side = min(source.size.width, source.size.height); source.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), from: NSRect(x: (source.size.width - side) / 2, y: (source.size.height - side) / 2, width: side, height: side), operation: .sourceOver, fraction: 1); result.unlockFocus(); result.isTemplate = false; return result }
}
struct PhoneView: View {
    @ObservedObject var model: SteveModel
    var body: some View { VStack(alignment: .leading, spacing: 10) { HStack { SteveLogo().frame(width: 28, height: 28); Text("Connect Phone").bold(); Spacer(); Button("Done", action: model.closePhonePairing) }; if let pairing = model.pairing { Text("Scan to open Messages, then send the one-time code below.").font(.caption).foregroundStyle(.secondary); QRCodeView(value: pairing.messageURI.isEmpty ? pairing.uri : pairing.messageURI).frame(width: 220, height: 220).frame(maxWidth: .infinity); Text(pairing.receiveAddress).font(.caption2).textSelection(.enabled); Text(pairing.code).font(.system(.body, design: .monospaced)).bold(); HStack { Button("Open Messages", action: model.openPairingMessage); Button("Copy Code", action: model.copyPairingCode) } } else { ProgressView("Preparing pairing QR…").frame(maxWidth: .infinity); Button("Try Again", action: model.startPhonePairing).frame(maxWidth: .infinity) } }.padding(16).frame(width: 350) }
}
struct QRCodeView: View {
    let value: String
    var body: some View { Group { if let image = makeImage() { Image(nsImage: image).resizable().interpolation(.none).scaledToFit() } else { Color.white } }.frame(width: 220, height: 220).background(.white) }
    private func makeImage() -> NSImage? { guard let data = value.data(using: .utf8), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }; filter.setValue(data, forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel"); guard let output = filter.outputImage else { return nil }; let modules = output.extent.width.rounded(); guard modules > 0 else { return nil }; let moduleSize = max(1, floor(196 / modules)); let scaled = output.transformed(by: CGAffineTransform(scaleX: moduleSize, y: moduleSize)); guard let cg = CIContext().createCGImage(scaled, from: scaled.extent.integral) else { return nil }; let codeSide = modules * moduleSize; let code = NSImage(cgImage: cg, size: NSSize(width: codeSide, height: codeSide)); let canvas = NSImage(size: NSSize(width: 220, height: 220)); canvas.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 220, height: 220).fill(); NSGraphicsContext.current?.imageInterpolation = .none; code.draw(in: NSRect(x: floor((220 - codeSide) / 2), y: floor((220 - codeSide) / 2), width: codeSide, height: codeSide), from: NSRect(origin: .zero, size: code.size), operation: .copy, fraction: 1); canvas.unlockFocus(); return canvas }
}
private func humanizeLabel(_ value: String) -> String { let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: ":")); if normalized == "danger-full-access" { return "Full Access" }; return normalized.split { $0 == "_" || $0 == "-" || $0 == " " }.map { token in switch token.lowercased() { case "api": return "API"; case "gpt": return "GPT"; case "id": return "ID"; case "ios": return "iOS"; case "imsg": return "iMessage"; case "mcp": return "MCP"; case "qr": return "QR"; case "url": return "URL"; case "xhigh": return "XHigh"; default: return token.prefix(1).uppercased() + token.dropFirst().lowercased() } }.joined(separator: " ") }
private func humanizeModelLabel(_ value: String) -> String { humanizeLabel(value) }
private func phoneDisplay(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : value }
private func permissionDescription(_ value: String) -> String { switch value.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased() { case "read-only": return "Read files without making changes."; case "workspace-write": return "Read and edit files inside the workspace."; case "danger-full-access": return "Run commands and use apps and websites without routine prompts. Account connections still need you."; default: return "Controls what Steve can do with your workspace." } }
private func modelDescription(_ value: String) -> String { let lower = value.lowercased(); if lower.contains("sol") { return "Highest capability for complex, long-running work." }; if lower.contains("terra") { return "Balanced speed and capability for everyday work." }; if lower.contains("luna") { return "Fast, efficient responses for lighter tasks." }; return "General-purpose model for everyday work." }
private func reasoningDescription(_ value: String) -> String { switch value.lowercased() { case "low": return "Fast responses with lighter reasoning."; case "medium": return "A balanced level of reasoning and speed."; case "high": return "More reasoning for complex tasks."; case "xhigh": return "Deep reasoning for demanding tasks."; default: return "Controls how much time Steve spends reasoning." } }
private func usageSubtitle(for window: RateWindow) -> String { let left = max(0, min(100, 100 - window.usedPercent)); let percent = String(format: "%.0f%% left", left); guard let reset = window.resetsAt else { return "\(percent), reset date unavailable" }; let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return "\(percent), \(formatter.string(from: Date(timeIntervalSince1970: reset)))" }

@MainActor
final class SteveAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = SteveModel.active else { return .terminateNow }
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct SteveNativeApp: App {
    @NSApplicationDelegateAdaptor(SteveAppDelegate.self) private var delegate
    @StateObject private var model = SteveModel()
    var body: some Scene {
        MenuBarExtra { StevePopover(model: model) } label: {
            if let image = SteveLogoSource.statusBarImage() { Image(nsImage: image) }
            else { Image(systemName: "terminal") }
        }.menuBarExtraStyle(.window)
    }
}

@main
enum SteveEntryPoint {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty { SteveNativeApp.main() }
        else { exit(SteveCLI.run(arguments)) }
    }
}
