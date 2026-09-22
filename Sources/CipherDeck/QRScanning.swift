import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision

// MARK: - Decode / generate

enum QRCode {
    /// All QR payload strings found in an image (a screenshot can contain several codes).
    static func decode(_ cgImage: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        var payloads = (request.results ?? []).compactMap(\.payloadStringValue)

        if payloads.isEmpty {
            // Fallback detector (handles some inverted / low-contrast codes).
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
            payloads = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }
        var seen = Set<String>()
        return payloads.filter { seen.insert($0).inserted }
    }

    static func decode(_ image: NSImage) -> [String] {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        return decode(cg)
    }

    static func decode(fileURL: URL) -> [String] {
        guard let image = NSImage(contentsOf: fileURL) else { return [] }
        return decode(image)
    }

    /// Black-on-white QR (best for phone cameras), scaled with crisp pixels.
    static func image(for payload: String, size: CGFloat = 320) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(size / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

// MARK: - Screen region capture

enum ScreenQRScanner {
    enum Outcome {
        case payloads([String])
        case cancelled
        case nothingFound
    }

    /// Lets the user drag-select a screen region (system `screencapture -i`) and decodes any
    /// QR codes in it. The temporary image lives in the per-user temp dir and is deleted
    /// immediately after decoding.
    static func scan() async -> Outcome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cipherdeck-scan-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let ok: Bool = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-o", "-r", url.path]
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
        guard ok, FileManager.default.fileExists(atPath: url.path) else { return .cancelled }
        let payloads = QRCode.decode(fileURL: url)
        return payloads.isEmpty ? .nothingFound : .payloads(payloads)
    }
}

// MARK: - Camera

/// Continuously scans the webcam for QR codes (e.g. Google Authenticator's
/// "Transfer accounts" screen held up to the Mac's camera).
final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable { case idle, running, denied, noCamera, failed }

    @Published var state: State = .idle
    let session = AVCaptureSession()
    var onPayloads: (([String]) -> Void)?

    private let queue = DispatchQueue(label: "cipherdeck.camera")
    private var lastScan = Date.distantPast
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureAndRun() } else { self?.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        state = .idle
    }

    private func configureAndRun() {
        guard let device = AVCaptureDevice.default(for: .video)
            ?? AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                mediaType: .video, position: .unspecified).devices.first
        else {
            state = .noCamera
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                guard let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.state = .failed }
                    return
                }
                self.session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(output) { self.session.addOutput(output) }
                self.session.commitConfiguration()
                self.configured = true
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.state = .running }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastScan) > 0.2,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = now
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !payloads.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onPayloads?(payloads) }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Mirror like a selfie camera so aligning the phone feels natural.
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
