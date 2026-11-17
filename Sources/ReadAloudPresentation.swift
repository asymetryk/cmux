import AppKit
import CmuxReadAloud
import SwiftUI
import UniformTypeIdentifiers

/// App-owned speech lifetime, native settings/player panels, and explicit save destinations.
@MainActor
final class ReadAloudPresentation: NSObject, NSWindowDelegate {
    private let preferences: ReadAloudPreferences
    private let coordinator: ReadAloudCoordinator
    private var settingsWindowController: NSWindowController?
    private var playerWindowController: NSWindowController?
    private var savePanel: NSSavePanel?
    private var readTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    var isSpeaking: Bool { coordinator.isSpeaking }
    var requiresShutdown: Bool { coordinator.requiresShutdown }

    override convenience init() {
        let preferences = ReadAloudPreferences(
            defaults: .standard,
            keychainService: "\(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app").read-aloud"
        )
        let coordinator = ReadAloudCoordinator(
            synthesizer: MiniMaxSpeechClient(session: URLSession(configuration: .ephemeral)),
            preferences: preferences,
            player: PCMReadAloudPlayer()
        )
        self.init(preferences: preferences, coordinator: coordinator)
    }

    init(preferences: ReadAloudPreferences, coordinator: ReadAloudCoordinator) {
        self.preferences = preferences
        self.coordinator = coordinator
        super.init()
    }

    func read(_ text: String) {
        stop()
        savePanel?.cancel(nil)
        let operation = generation
        readTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { showPlayer() }
            do {
                try await coordinator.read(text)
            } catch is CancellationError {
                // Stop and replacement are deliberate, not user-facing failures.
            } catch {
                guard generation == operation else { return }
                if let error = error as? ReadAloudCoordinatorError,
                   case .configurationRequired = error {
                    playerWindowController?.window?.orderOut(nil)
                    showSettings()
                } else if coordinator.errorMessage == nil {
                    showError(error)
                }
                // Other failures remain visible in the player, with partial audio still saveable.
            }
            if generation == operation { readTask = nil }
        }
    }

    func stop() {
        generation &+= 1
        readTask?.cancel()
        readTask = nil
        coordinator.stop()
    }

    func dismissPlayer() {
        stop()
        savePanel?.cancel(nil)
        coordinator.dismiss()
    }

    func finishForTermination() async {
        stop()
        savePanel?.cancel(nil)
        await coordinator.finishDismissal()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === playerWindowController?.window else { return }
        dismissPlayer()
    }

    private func showPlayer() {
        if let window = playerWindowController?.window {
            window.orderFront(nil)
            return
        }
        let view = ReadAloudPlayerView(coordinator: coordinator, onSave: { [weak self] in
            self?.saveAudio()
        }, onSettings: { [weak self] in
            self?.showSettings()
        })
        let window = NSPanel(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "terminalContextMenu.readAloud", defaultValue: "Read Aloud")
        window.styleMask = [.titled, .closable, .nonactivatingPanel]
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("ReadAloudPlayerWindow")
        window.center()
        playerWindowController = NSWindowController(window: window)
        // Never activate the app or take keyboard focus away from the terminal selection.
        window.orderFront(nil)
    }

    private func saveAudio() {
        guard savePanel == nil, coordinator.hasRecording,
              let window = playerWindowController?.window else { return }
        let recordingID = coordinator.recordingID
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "Read Aloud.m4a"
        panel.canCreateDirectories = true
        savePanel = panel
        Task { [weak self] in
            guard let self else { return }
            let response = await panel.beginSheetModal(for: window)
            if savePanel === panel { savePanel = nil }
            guard response == .OK, let url = panel.url,
                  coordinator.recordingID == recordingID else { return }
            do {
                try await coordinator.save(to: url)
            } catch is CancellationError {
                // A dismissed or replaced recording cannot save the next selection by mistake.
            } catch {
                // The coordinator presents safe errors in the player without interrupting playback.
            }
        }
    }

    func showSettings() {
        if let settingsWindowController {
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = ReadAloudSettingsModel(preferences: preferences)
        let content = NSHostingController(rootView: ReadAloudSettingsView(model: model))
        let window = NSWindow(contentViewController: content)
        window.title = String(localized: "readAloud.settingsTitle", defaultValue: "Read Aloud Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func showError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "readAloud.errorTitle", defaultValue: "Unable to Read Aloud")
        alert.informativeText = (error as? any LocalizedError)?.errorDescription
            ?? String(localized: "readAloud.errorMessage", defaultValue: "Speech playback failed. Check your connection and Read Aloud settings, then try again.")
        alert.addButton(withTitle: String(localized: "readAloud.dismiss", defaultValue: "OK"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
