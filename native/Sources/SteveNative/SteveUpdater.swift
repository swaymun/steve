import AppKit
import Sparkle

/// Sparkle owns download, signature checks, installation, and relaunch. Steve
/// only chooses a safe moment to hand an already verified update to it.
@MainActor
final class SteveUpdater: NSObject, SPUUpdaterDelegate {
    private let runtime: SteveRuntime
    private var controller: SPUStandardUpdaterController?
    private var installTask: Task<Void, Never>?

    init(runtime: SteveRuntime) {
        self.runtime = runtime
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }
    var automaticUpdatesEnabled: Bool { controller?.updater.automaticallyChecksForUpdates == true && controller?.updater.automaticallyDownloadsUpdates == true }
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates == true }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock handler: @escaping () -> Void) -> Bool {
        installWhenIdle(handler)
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        installWhenIdle(handler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: Error?) {
        guard error != nil else { return }
        installTask?.cancel()
        installTask = nil
        Task { await runtime.cancelUpdateRestart() }
    }

    private func installWhenIdle(_ handler: @escaping () -> Void) {
        installTask?.cancel()
        installTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if await runtime.reserveUpdateRestart() {
                    guard !Task.isCancelled else {
                        await runtime.cancelUpdateRestart()
                        return
                    }
                    handler()
                    return
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
}
