import SwiftUI
import AppKit

@main
struct WhaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater.shared
    @AppStorage("showMenuBar") private var showMenuBar = false

    var body: some Scene {
        Window("Whale", id: "library") {
            LibraryView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear { delegate.model = model; updater.model = model; model.installHotKey(); NSApp.applicationIconImage = WhaleBrand.mark }
        }
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates || model.isRecording || model.busy)
                Divider()
                Button("Settings…") { model.showingSettings = true; showLibrary() }
                    .keyboardShortcut(",")
            }
            CommandMenu("Meeting") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                    .disabled(model.busy || model.store == nil)
                Button("Show Library") { showLibrary() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Hide Whale") { NSApp.hide(nil) }.keyboardShortcut("h")
            }
        }
        MenuBarExtra(isInserted: $showMenuBar) {
            Button("Open Meeting Library") { showLibrary() }
            Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                .disabled(model.busy || model.store == nil)
            Divider()
            Button("Quit Whale") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: WhaleBrand.menuBarMark).accessibilityLabel("Whale")
        }
    }
    private func showLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" || $0.title == "Whale" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.title == "Whale" })?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.starting || model.stopping {
            model.error = "Wait for audio capture to finish starting or stopping before quitting."
            return .terminateCancel
        }
        guard model.isRecording || model.processingID != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.isRecording ? "Stop recording and quit?" : "Pause processing and quit?"
        alert.informativeText = "Your saved audio and completed transcription parts will remain in the library."
        alert.addButton(withTitle: "Keep Whale Open")
        alert.addButton(withTitle: "Save and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            if model.isRecording { await model.stopRecording(process: false) }
            model.cancelProcessing()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
