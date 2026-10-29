import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    weak var model: AppModel?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var configurationError: String?
    private var observation: AnyCancellable?
    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        do { try controller.updater.start() }
        catch { configurationError = error.localizedDescription }
    }

    var automaticallyUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if model == nil || model!.isRecording || model!.busy {
            throw NSError(domain: "Whale.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Updates will resume when recording and processing have finished."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model, model.isRecording || model.busy else { return false }
        Task { @MainActor in
            while model.isRecording || model.busy {
                try? await Task.sleep(for: .seconds(1))
            }
            installHandler()
        }
        return true
    }
}
