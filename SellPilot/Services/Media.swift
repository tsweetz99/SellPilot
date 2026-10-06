import SwiftUI
import UIKit
import Speech
import AVFoundation
import Observation

enum PhotoImport {
    static func normalized(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
    }
    static func demoPhoto() -> Data {
        let size = CGSize(width: 800, height: 600)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemGray6.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIImage(systemName: "wrench.and.screwdriver.fill")?.withTintColor(.systemYellow, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 240, y: 130, width: 320, height: 320))
            ("DEMO PHOTO • NOT A REAL PRODUCT" as NSString).draw(at: CGPoint(x: 165, y: 510), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 23), .foregroundColor: UIColor.darkGray])
        }.jpegData(compressionQuality: 0.9)!
    }
}
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { parent.onImage(data) }; parent.dismiss() }
    }
}
@MainActor @Observable final class DictationController {
    var recording = false
    var transcript = ""
    var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var installedTap = false
    private var sessionToken = UUID()
    func start() async {
        let token = UUID(); sessionToken = token
        let authorized = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
        let microphone = await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
        guard sessionToken == token else { return }
        guard authorized, microphone else { error = "Allow microphone and speech recognition in Settings, or type your note."; return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { error = "Dictation is unavailable. You can still type a note."; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest(); request.shouldReportPartialResults = true; self.request = request; transcript = ""
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw ServiceError.invalid("No microphone input is available.") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; installedTap = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard self?.sessionToken == token else { return }
                    if let result { self?.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self?.stop() }
                }
            }
            engine.prepare(); try engine.start(); recording = true
        } catch { stop(); self.error = error.localizedDescription }
    }
    func stop() {
        sessionToken = UUID()
        engine.stop(); if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
