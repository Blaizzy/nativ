import Foundation
import NativExtensionSDK
import SwiftUI

@MainActor
final class VoiceDictationExtension: NativHostExtension {
    static let showRecordingsCommandID =
        "com.nativ.voice-dictation.show-recordings"

    let manifest: NativExtensionManifest

    private let coordinator = VoiceCaptureCoordinator()
    private let audioCaptureLibrary = AudioCaptureLibrary()
    private var isActive = false

    init(bundle: Bundle = .main) {
        manifest =
            Self.loadBundledManifest(bundle: bundle)
            ?? Self.fallbackManifest
    }

    func activate(context: NativExtensionHostContext) {
        guard !isActive else {
            return
        }
        coordinator.transcriptionConfigurationProvider = context.transcriptionConfiguration
        audioCaptureLibrary.transcriptionConfigurationProvider = context.transcriptionConfiguration
        coordinator.onOpenSpeechModels = {
            context.openSpeechModels()
            context.showMainWindow()
        }
        coordinator.start()
        isActive = true
    }

    func deactivate() {
        guard isActive else {
            return
        }
        coordinator.stop()
        audioCaptureLibrary.shutdown()
        coordinator.transcriptionConfigurationProvider = nil
        audioCaptureLibrary.transcriptionConfigurationProvider = nil
        coordinator.onOpenSpeechModels = nil
        isActive = false
    }

    func makePage(
        id: String,
        context: NativExtensionPageContext
    ) -> AnyView? {
        guard id == NativExtensionManager.voiceAudioPageID else {
            return nil
        }
        return AnyView(
            AudioView(
                model: context.model,
                captureLibrary: audioCaptureLibrary,
                titleLeadingInset: context.titleLeadingInset,
                onOpenSpeechModels: context.openSpeechModels
            )
        )
    }

    func performCommand(id: String) {
        guard id == Self.showRecordingsCommandID else {
            return
        }
        audioCaptureLibrary.revealLibrary()
    }

    private static func loadBundledManifest(
        bundle: Bundle
    ) -> NativExtensionManifest? {
        let candidates = [
            bundle.resourceURL?
                .appendingPathComponent("VoiceDictation", isDirectory: true)
                .appendingPathComponent("Manifest.json"),
            bundle.url(forResource: "Manifest", withExtension: "json"),
        ]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(
                    NativExtensionManifest.self,
                    from: data
                  ) else {
                continue
            }
            return manifest
        }
        return nil
    }

    private static let fallbackManifest = NativExtensionManifest(
        id: NativExtensionManager.voiceDictationID,
        version: "1.0.0",
        minimumNativVersion: "0.1.0",
        displayName: "Audio",
        summary: "Private, local audio capabilities including meeting capture, voice notes, transcription, summaries, dictation, analytics, and shortcuts.",
        developer: "Nativ",
        systemImage: "waveform.badge.mic",
        included: true,
        runtime: .extensionFoundation,
        runtimeBundleIdentifier: "dev.local.Nativ.VoiceDictationExtension",
        contributions: .init(
            sidebar: [
                .init(
                    id: NativExtensionManager.voiceAudioPageID,
                    title: "Audio",
                    systemImage: "waveform.badge.mic",
                    order: 250
                )
            ],
            commands: [
                .init(
                    id: showRecordingsCommandID,
                    title: "Show Audio Library",
                    systemImage: "waveform"
                )
            ],
            shortcuts: [
                .init(
                    id: "com.nativ.voice-dictation.transcribe",
                    title: "Transcribe",
                    defaultShortcut: "Fn+Control"
                ),
                .init(
                    id: "com.nativ.voice-dictation.retranscribe",
                    title: "Retranscribe",
                    defaultShortcut: "Fn+R"
                ),
                .init(
                    id: "com.nativ.voice-dictation.hands-free",
                    title: "Hands-free",
                    defaultShortcut: "Option"
                ),
            ],
            settings: [
                .init(id: "com.nativ.voice-dictation.model", title: "Speech-to-text model"),
                .init(id: "com.nativ.voice-dictation.animation", title: "Animation"),
                .init(id: "com.nativ.voice-dictation.shortcuts", title: "Shortcuts"),
            ]
        ),
        permissions: [
            .microphone,
            .systemAudioCapture,
            .accessibilityInsertText,
            .modelsSpeechToText,
            .overlay,
            .namespacedStorage,
        ]
    )
}
