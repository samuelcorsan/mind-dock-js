import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import Speech
import SwiftUI

private final class SpeechChannel {
    private let queue: DispatchQueue
    private let locale: Locale
    private let onChange: (String) -> Void
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var partial = ""
    private var generation = 0

    init(name: String, locale: Locale, onChange: @escaping (String) -> Void) {
        self.queue = DispatchQueue(label: "dev.disam.minddock.speech.\(name)")
        self.locale = locale
        self.onChange = onChange
    }

    func start() throws {
        guard let candidate = SFSpeechRecognizer(locale: locale), candidate.supportsOnDeviceRecognition else {
            throw RecordingError("On-device transcription is unavailable for \(locale.identifier). Try another language.")
        }
        queue.sync { startRequest(with: candidate) }
    }

    private func startRequest(with recognizer: SFSpeechRecognizer) {
        generation += 1
        let currentGeneration = generation
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == currentGeneration else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    self.onChange((self.committed + " " + self.partial).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if error != nil { self.onChange((self.committed + " " + self.partial).trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.sync { request?.appendAudioSampleBuffer(sampleBuffer) }
    }

    func rotate() {
        queue.async { [weak self] in
            guard let self, let oldRecognizer = self.recognizer else { return }
            if !self.partial.isEmpty { self.committed += (self.committed.isEmpty ? "" : " ") + self.partial }
            self.partial = ""
            self.task?.cancel()
            self.request?.endAudio()
            self.startRequest(with: SFSpeechRecognizer(locale: self.locale) ?? oldRecognizer)
        }
    }

    func finish() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: ""); return }
                self.request?.endAudio()
                self.queue.asyncAfter(deadline: .now() + 2.5) {
                    let text = (self.committed + " " + self.partial).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.task?.cancel()
                    continuation.resume(returning: text)
                }
            }
        }
    }
}

private struct RecordingError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class MeetingRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var startedAt: Date?

    private var stream: SCStream?
    private var systemChannel: SpeechChannel?
    private var microphoneChannel: SpeechChannel?
    private var systemText = ""
    private var microphoneText = ""
    private var rotationTimer: Timer?

    @MainActor func start(language: String) async throws {
        guard !isRecording else { return }
        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechPermission == .authorized else { throw RecordingError("Allow Speech Recognition in System Settings to transcribe meetings.") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecordingError("Allow Microphone access in System Settings to record your voice.") }

        let locale = Locale(identifier: language)
        let system = SpeechChannel(name: "system", locale: locale) { [weak self] text in
            DispatchQueue.main.async { self?.systemText = text; self?.updateTranscript() }
        }
        let microphone = SpeechChannel(name: "microphone", locale: locale) { [weak self] text in
            DispatchQueue.main.async { self?.microphoneText = text; self?.updateTranscript() }
        }
        try system.start()
        try microphone.start()
        systemChannel = system
        microphoneChannel = microphone
        systemText = ""
        microphoneText = ""
        liveTranscript = ""

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw RecordingError("No display is available for audio capture.") }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.captureMicrophone = true
            configuration.excludesCurrentProcessAudio = true
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "dev.disam.minddock.system-audio"))
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "dev.disam.minddock.microphone"))
            try await stream.startCapture()
            self.stream = stream
            startedAt = Date()
            isRecording = true
            rotationTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
                self?.systemChannel?.rotate()
                self?.microphoneChannel?.rotate()
            }
        } catch {
            systemChannel = nil
            microphoneChannel = nil
            if error.localizedDescription.contains("TCCs") {
                throw RecordingError("Allow MindDock in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen MindDock.")
            }
            throw error
        }
    }

    @MainActor func stop() async throws -> String {
        guard isRecording, let stream else { return liveTranscript }
        rotationTimer?.invalidate()
        rotationTimer = nil
        try await stream.stopCapture()
        self.stream = nil
        isRecording = false
        async let system = systemChannel?.finish() ?? ""
        async let microphone = microphoneChannel?.finish() ?? ""
        systemText = await system
        microphoneText = await microphone
        updateTranscript()
        systemChannel = nil
        microphoneChannel = nil
        return liveTranscript
    }

    @MainActor private func updateTranscript() {
        let me = microphoneText.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscript = [me.isEmpty ? nil : "Me:\n\(me)", others.isEmpty ? nil : "Call audio:\n\(others)"]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio: systemChannel?.append(sampleBuffer)
        case .microphone: microphoneChannel?.append(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.rotationTimer?.invalidate()
        }
    }
}

struct RecordingView: View {
    @Environment(\.dismiss) private var dismiss
    let api: APIClient
    @ObservedObject var recorder: MeetingRecorder
    let personID: String
    @Binding var title: String
    @Binding var language: String
    let onCreated: (Meeting) -> Void
    @State private var transcript = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Record meeting").font(.title2.bold())
                Spacer()
                if recorder.isRecording { Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red) }
            }
            TextField("Meeting title (optional)", text: $title)
            Picker("Language", selection: $language) {
                Text("English").tag("en-US")
                Text("Español").tag("es-ES")
            }
            .disabled(recorder.isRecording)
            Text("Captures your microphone and call audio. Only the transcript is saved to MindDock; no audio file is kept.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if recorder.isRecording {
                    Button("Stop and transcribe", systemImage: "stop.fill") {
                        Task {
                            do { transcript = try await recorder.stop() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start recording", systemImage: "record.circle") {
                        Task {
                            do { try await recorder.start(language: language) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Close") { dismiss() }.disabled(recorder.isRecording)
            }
            Text("Transcript").font(.headline)
            TextEditor(text: $transcript)
                .frame(minHeight: 220)
                .border(.quaternary)
                .onChange(of: recorder.liveTranscript) { _, newValue in
                    if recorder.isRecording { transcript = newValue }
                }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(saving ? "Saving…" : "Save meeting") {
                    saving = true
                    Task {
                        do {
                            let meeting: Meeting = try await api.post("/meetings", body: MeetingInput(personId: personID, title: title.isEmpty ? nil : title, startedAt: ISO8601DateFormatter().string(from: recorder.startedAt ?? Date()), endedAt: ISO8601DateFormatter().string(from: Date()), summary: nil, transcript: transcript))
                            onCreated(meeting)
                            dismiss()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.isRecording || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 660, height: 590)
        .interactiveDismissDisabled(recorder.isRecording)
    }
}
