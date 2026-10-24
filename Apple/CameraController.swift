import AVFoundation
import Photos
import UIKit
import os

struct CaptureCapabilities: Equatable {
    var machine: String
    var systemVersion: String
    var physicalMemoryGB: Double
    var rawFormats: [String]
    var processedFormats: [String]
    var activeWidth: Int
    var activeHeight: Int
    var minExposureSeconds: Double
    var maxExposureSeconds: Double
    var minISO: Float
    var maxISO: Float
    var hasFlash: Bool
    var hasTorch: Bool

    var report: String {
        var lines: [String] = []
        lines.append("Aparelho: \(machine)")
        lines.append("iOS: \(systemVersion)")
        lines.append(String(format: "Memoria fisica: %.2f GB", physicalMemoryGB))
        lines.append("Formato ativo: \(activeWidth)x\(activeHeight)")
        lines.append(String(format: "Exposicao: %.6fs a %.6fs", minExposureSeconds, maxExposureSeconds))
        lines.append(String(format: "ISO: %.0f a %.0f", minISO, maxISO))
        lines.append("Flash: \(hasFlash ? "sim" : "nao") / Tocha: \(hasTorch ? "sim" : "nao")")
        lines.append("Formatos RAW disponiveis: \(rawFormats.isEmpty ? "nenhum" : rawFormats.joined(separator: ", "))")
        lines.append("Formatos processados: \(processedFormats.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var status = "Iniciando..."
    @Published var capabilities: CaptureCapabilities?
    @Published var lastCaptureNote = ""
    @Published var isConfigured = false
    @Published var isProbingRaw = false
    @Published var rawProbeReport: String?
    @Published var isCapturingBurst = false
    @Published var diagnosticNote = ""
    @Published var diagnosticBytes: Int64 = 0
    @Published var focusHint = ""
    @Published var lastPhotoThumbnail: UIImage?
    private(set) var lastPhotoData: Data?
    @Published var appleRawStatus = ""
    @Published var appleRawReferenceData: Data?

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let previewOutput = AVCaptureVideoDataOutput()
    private let previewSampler = BurstPreviewSampler()
    // All preview state and callbacks are serialized on sessionQueue.
    private var latestPreview: BurstPreviewSample?
    private var burstPreview: BurstPreviewSample?
    private var lastPreviewSampleTime: CFAbsoluteTime = 0
    private var focusGeneration = UUID()
    private var focusRequestedAt: CFAbsoluteTime = 0
    private let sessionQueue = DispatchQueue(label: "dev.lucas.burstlab.session")
    private let processingQueue = DispatchQueue(label: "dev.lucas.burstlab.processing", qos: .userInitiated)
    private let burstLog = Logger(subsystem: "dev.lucas.burstlab", category: "burst")
    private var photoDevice: AVCaptureDevice?
    private var configured = false
    private var probeActive = false
    private var probeRemaining = 0
    private var probeLines: [String] = []
    private var probeStart: CFTimeInterval = 0
    private var probeIntervalStart: CFTimeInterval?
    private var calibrationBuffer: CVPixelBuffer?
    private var processingActive = false
    private var singleCaptureActive = false
    private enum CaptureRequest { case photo, probe, burst }
    // Access only on sessionQueue; late callbacks cannot enter another capture.
    private var requests: [Int64: CaptureRequest] = [:]
    private var burstGeneration = UUID()
    private var savedCameraModes: (exposure: AVCaptureDevice.ExposureMode, focus: AVCaptureDevice.FocusMode, whiteBalance: AVCaptureDevice.WhiteBalanceMode)?
    private var savedFrameDurations: (min: CMTime, max: CMTime)?
    private var burstActive = false
    private var burstFrames: [BurstFrame] = []
    private var burstRemaining = 0
    private var burstFormat: OSType = 0
    private var burstStart: CFTimeInterval = 0
    private var burstConfig = BurstConfig.defaults(for: .photo)
    private var burstPlan: BurstCapturePlan?
    private var burstExposureReadings: [[String: Double]] = []
    private var burstCurrentShort = false
    private var burstFreshness = BurstFrameFreshness()
    private var burstDuplicateRetries = 0
    private var burstLastRequestAt: CFAbsoluteTime = 0
    private var burstLastRequestDuration = 0.0
    private var burstRetries = 0
    private var burstReadinessPolls = 0
    private var burstRotationAngle = 90
    private var burstNoiseProfile: [Double]?
    private var burstAsShotNeutral: [Double]?
    private var burstRecordDiagnostics = false
    private var burstReferenceDNG: Data?
    private var burstColorMatrix1: [Double]?
    private var burstColorMatrix2: [Double]?
    private var burstIlluminant1 = 17
    private var burstIlluminant2 = 21
    private var rotationCoordinatorStorage: Any?

    func start() {
        refreshDiagnosticStorage()
        #if targetEnvironment(simulator)
        status = "Simulador sem camera. Rode no iPhone fisico."
        #else
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.status = "Acesso a camera negado nos Ajustes." }
                return
            }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if self.configured, !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    self.isConfigured = self.configured
                    if self.configured {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                }
                self.publishCapabilities()
                if #available(iOS 17.0, *), let device = self.photoDevice {
                    self.rotationCoordinatorStorage = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                }
            }
        }
        #endif
    }

    func stop() {
        sessionQueue.async {
            if self.burstActive { self.abortBurst("Burst interrompido ao fechar a camera.") }
            if self.probeActive { self.finishRawProbe(status: "Sonda interrompida ao fechar a camera.") }
            self.requests.removeAll()
            self.singleCaptureActive = false
            self.latestPreview = nil
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
    }

    func refreshDiagnosticStorage(removeAll: Bool = false) {
        processingQueue.async {
            do {
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true)
                let storage = BurstDiagnosticStorage(documents: documents)
                if removeAll { try storage.removeAll() } else { try storage.prune() }
                let bytes = try storage.usageBytes()
                DispatchQueue.main.async {
                    self.diagnosticBytes = bytes
                    if removeAll {
                        self.diagnosticNote = "RAWs de diagnostico apagados."
                        self.appleRawReferenceData = nil
                        self.appleRawStatus = ""
                    }
                }
            } catch {
                DispatchQueue.main.async { self.diagnosticNote = "Falha na limpeza dos RAWs: \(error.localizedDescription)" }
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async {
            guard self.configured, self.session.isRunning, !self.probeActive, !self.burstActive, !self.processingActive, !self.singleCaptureActive else {
                DispatchQueue.main.async { self.status = "Sessao de camera indisponivel." }
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .quality
            self.singleCaptureActive = true
            self.submitPhoto(settings, kind: .photo)
        }
    }

    func focus(at point: CGPoint, completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            guard self.configured, self.session.isRunning, !self.burstActive, !self.processingActive,
                  !self.probeActive, !self.singleCaptureActive, point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y),
                  let device = self.photoDevice, device.isFocusPointOfInterestSupported,
                  device.isFocusModeSupported(.continuousAutoFocus) else {
                DispatchQueue.main.async { completion(false) }; return
            }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
                self.focusGeneration = UUID()
                self.focusRequestedAt = CFAbsoluteTimeGetCurrent()
                self.latestPreview = nil
                let generation = self.focusGeneration
                DispatchQueue.main.async { self.focusHint = "Ajustando foco e luz…" }
                self.waitForFocus(generation: generation, polls: 0, completion: completion)
            } catch {
                DispatchQueue.main.async { self.focusHint = "Nao foi possivel ajustar o foco."; completion(false) }
            }
        }
    }

    private func waitForFocus(generation: UUID, polls: Int, completion: @escaping (Bool) -> Void) {
        guard generation == focusGeneration, let device = photoDevice else {
            DispatchQueue.main.async { completion(false) }; return
        }
        let settling = polls < 2 || device.isAdjustingFocus || device.isAdjustingExposure
        if settling, polls < 25 {
            sessionQueue.asyncAfter(deadline: .now() + 0.1) {
                self.waitForFocus(generation: generation, polls: polls + 1, completion: completion)
            }
            return
        }
        let settled = !settling
        DispatchQueue.main.async {
            self.focusHint = settled ? "Ponto de foco definido" : "Pouca luz para confirmar o foco"
            completion(settled)
        }
    }

    func compareAppleRAW() {
        sessionQueue.async {
            guard self.configured, !self.burstActive, !self.processingActive,
                  !self.singleCaptureActive, !self.probeActive else { return }
            self.processingActive = true
            DispatchQueue.main.async {
                self.isCapturingBurst = true
                self.status = "Preparando comparacao Apple…"
                self.appleRawStatus = "Revelando um RAW guardado…"
                self.appleRawReferenceData = nil
            }
            self.processingQueue.async {
                do {
                    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: false)
                    let directory = try BurstAppleRAWReference.latestDirectory(in: documents)
                    let result = try BurstAppleRAWReference.render(directory: directory)
                    let decoder = result.report["decoder_effective"] as? String ?? "?"
                    DispatchQueue.main.async {
                        self.appleRawReferenceData = result.jpeg
                        self.appleRawStatus = "Comparacao pronta · decoder \(decoder) · RAW individual, meia resolucao."
                        self.status = "Comparacao pronta"
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.appleRawStatus = error.localizedDescription
                        self.status = "Comparacao indisponivel"
                    }
                }
                self.completeBurstProcessing()
            }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = "Nenhuma camera traseira encontrada." }
            return
        }
        session.addInput(input)
        photoDevice = device

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = "Saida de fotos indisponivel." }
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        previewOutput.alwaysDiscardsLateVideoFrames = true
        previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(previewOutput) {
            session.addOutput(previewOutput)
            previewOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            if #available(iOS 17.0, *), let connection = previewOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        }
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard (!burstActive || burstPlan == nil), !processingActive, !probeActive, !singleCaptureActive,
              CFAbsoluteTimeGetCurrent() - lastPreviewSampleTime >= 0.25,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Reject a queued video frame from before a session interruption.
        let age = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()) - CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard age.isFinite, age >= -0.1, age <= 0.5 else { return }
        lastPreviewSampleTime = CFAbsoluteTimeGetCurrent()
        latestPreview = previewSampler.sample(buffer)
    }

    private func publishCapabilities() {
        guard let device = photoDevice else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let capabilities = CaptureCapabilities(
            machine: CameraController.machineIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            rawFormats: photoOutput.availableRawPhotoPixelFormatTypes.map { CameraController.fourCC($0) },
            processedFormats: photoOutput.availablePhotoPixelFormatTypes.map { CameraController.fourCC($0) },
            activeWidth: Int(dimensions.width),
            activeHeight: Int(dimensions.height),
            minExposureSeconds: CMTimeGetSeconds(device.activeFormat.minExposureDuration),
            maxExposureSeconds: CMTimeGetSeconds(device.activeFormat.maxExposureDuration),
            minISO: device.activeFormat.minISO,
            maxISO: device.activeFormat.maxISO,
            hasFlash: device.hasFlash,
            hasTorch: device.hasTorch
        )
        DispatchQueue.main.async {
            self.capabilities = capabilities
            self.status = "Pronto"
        }
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "0x" + String(value, radix: 16)
    }

    func probeRawBurst() {
        sessionQueue.async {
            guard self.configured, self.session.isRunning, !self.probeActive, !self.burstActive, !self.processingActive, !self.singleCaptureActive else { return }
            guard let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first else {
                DispatchQueue.main.async { self.rawProbeReport = "Nenhum formato RAW disponivel neste aparelho." }
                return
            }
            self.probeActive = true
            self.probeRemaining = 8
            self.probeLines.removeAll()
            self.probeStart = CFAbsoluteTimeGetCurrent()
            self.probeIntervalStart = nil
            DispatchQueue.main.async {
                self.isProbingRaw = true
                self.rawProbeReport = nil
                self.status = "Sondando burst RAW..."
            }
            self.captureRawProbeFrame(format: rawFormat)
        }
    }

    private func captureRawProbeFrame(format: OSType) {
        let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
        submitPhoto(settings, kind: .probe)
    }

    private func handleRawProbeFrame(_ photo: AVCapturePhoto, error: Error?) {
        let frameNumber = 9 - probeRemaining
        if let error {
            probeLines.append("Frame \(frameNumber): erro \(error.localizedDescription)")
            finishRawProbe(status: "Sonda RAW interrompida")
            return
        }
        guard let pixelBuffer = photo.pixelBuffer else {
            probeLines.append("Frame \(frameNumber): sem pixel buffer RAW")
            finishRawProbe(status: "Sonda RAW interrompida")
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let interval = now - (probeIntervalStart ?? probeStart)
        probeIntervalStart = now
        if frameNumber == 1 { calibrationBuffer = pixelBuffer }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var range = "sem amostras"
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer), rowBytes >= width * 2 {
            var minimum = UInt32.max
            var maximum: UInt32 = 0
            var total: UInt64 = 0
            var count: UInt64 = 0
            for y in stride(from: 0, to: height, by: 8) {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in stride(from: 0, to: width, by: 8) {
                    let value = UInt32(row[x])
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    total += UInt64(value)
                    count += 1
                }
            }
            let mean = count > 0 ? Double(total) / Double(count) : 0
            range = String(format: "min %u media %.0f max %u", minimum, mean, maximum)
        }
        probeLines.append(String(
            format: "Frame %d: %.1f ms, %dx%d, %d B/linha, FourCC %@, %@",
            frameNumber, interval * 1000, width, height, rowBytes,
            CameraController.fourCC(format), range
        ))

        probeRemaining -= 1
        if probeRemaining > 0, let nextFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            captureRawProbeFrame(format: nextFormat)
        } else {
            finishRawProbe(status: "Sonda RAW concluida. Abra o relatorio (i).")
        }
    }

    private static func analyzeRaw(_ pixelBuffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), rowBytes >= width * 2 else {
            return "Calibracao RAW: buffer indisponivel."
        }
        var histogram = [Int](repeating: 0, count: 65536)
        var phaseTotal = [Double](repeating: 0, count: 4)
        var phaseCount = [Int](repeating: 0, count: 4)
        var twoBitViolations = 0
        var fourBitViolations = 0
        var minimum = 65535
        var maximum = 0
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            let phaseRow = (y & 1) << 1
            for x in 0..<width {
                let value = Int(row[x])
                histogram[value] += 1
                let phase = phaseRow | (x & 1)
                phaseTotal[phase] += Double(value)
                phaseCount[phase] += 1
                if value & 0x3 != 0 { twoBitViolations += 1 }
                if value & 0xF != 0 { fourBitViolations += 1 }
                if value < minimum { minimum = value }
                if value > maximum { maximum = value }
            }
        }
        let samples = width * height
        func percentile(_ fraction: Double) -> Int {
            let target = Int(Double(samples) * fraction)
            var accumulated = 0
            for value in 0..<65536 {
                accumulated += histogram[value]
                if accumulated >= target { return value }
            }
            return 65535
        }
        let modes = histogram.enumerated().sorted { $0.element > $1.element }.prefix(4)
        let modeText = modes.map { String(format: "%d(%d)", $0.offset, $0.element) }.joined(separator: " ")
        let alignment: String
        if twoBitViolations == 0 {
            alignment = "14 bits a esquerda (real = bruto >> 2)"
        } else if fourBitViolations == 0 {
            alignment = "12 bits a esquerda (real = bruto >> 4)"
        } else {
            alignment = "alinhado a direita"
        }
        let phases = ["R(0,0)", "G(1,0)", "G(0,1)", "B(1,1)"]
        let phaseText = (0..<4).map { index in
            let mean = phaseCount[index] > 0 ? phaseTotal[index] / Double(phaseCount[index]) : 0
            return String(format: "%@ %.0f", phases[index], mean)
        }.joined(separator: " ")
        return [
            "Calibracao RAW (frame 1, frame inteiro):",
            String(format: "  min %d max %d | P0.01 %d P0.1 %d P1 %d P50 %d P99 %d P99.9 %d P99.99 %d",
                   minimum, maximum, percentile(0.0001), percentile(0.001), percentile(0.01),
                   percentile(0.5), percentile(0.99), percentile(0.999), percentile(0.9999)),
            "  top valores: \(modeText)",
            "  bits baixos: \(alignment) | violacoes 2 bits \(twoBitViolations) | 4 bits \(fourBitViolations)",
            "  CFA RGGB: \(phaseText)"
        ].joined(separator: "\n")
    }

    private func finishRawProbe(status: String) {
        requests = requests.filter { $0.value != .probe }
        let elapsed = CFAbsoluteTimeGetCurrent() - probeStart
        let validFrames = probeLines.filter { $0.hasPrefix("Frame ") && !$0.contains("erro") }.count
        let rate = elapsed > 0 ? Double(validFrames) / elapsed : 0
        var lines = [
            String(format: "BURST RAW: %d frames em %.2fs (%.1f fps)", validFrames, elapsed, rate),
            "Termica ao final: \(CameraController.thermalStateName(ProcessInfo.processInfo.thermalState))"
        ]
        lines.append(contentsOf: probeLines)
        if let buffer = calibrationBuffer {
            lines.append(CameraController.analyzeRaw(buffer))
            calibrationBuffer = nil
        }
        let report = lines.joined(separator: "\n")
        probeActive = false
        DispatchQueue.main.async {
            self.isProbingRaw = false
            self.rawProbeReport = report
            self.status = status
        }
    }

    func captureBurst(mode: CaptureMode = .photo, recordDiagnostics: Bool = false) {
        sessionQueue.async {
            self.burstLog.notice("captureBurst configured=\(self.configured, privacy: .public) running=\(self.session.isRunning, privacy: .public) probe=\(self.probeActive, privacy: .public) burst=\(self.burstActive, privacy: .public)")
            guard self.configured, self.session.isRunning, !self.probeActive, !self.burstActive, !self.processingActive, !self.singleCaptureActive else { return }
            guard self.photoOutput.availableRawPhotoPixelFormatTypes.contains(kCVPixelFormatType_14Bayer_RGGB) else {
                DispatchQueue.main.async { self.lastCaptureNote = "Burst requer RAW Bayer RGGB de 14 bits calibrado para este aparelho." }
                return
            }
            let rawFormat = kCVPixelFormatType_14Bayer_RGGB
            guard self.photoDevice != nil else { return }
            self.burstConfig = BurstConfig.defaults(for: mode)
            self.burstPreview = nil
            self.burstActive = true
            self.burstGeneration = UUID()
            let generation = self.burstGeneration
            self.burstPlan = nil
            self.burstExposureReadings.removeAll()
            self.burstCurrentShort = false
            self.burstFreshness = BurstFrameFreshness()
            self.burstDuplicateRetries = 0
            self.burstLastRequestAt = 0
            self.burstLastRequestDuration = 0
            self.burstFormat = rawFormat
            self.burstFrames.removeAll()
            self.burstRemaining = self.burstConfig.frameCount
            self.burstRetries = 0
            self.burstReadinessPolls = 0
            self.burstAsShotNeutral = nil
            self.burstNoiseProfile = nil
            self.burstRecordDiagnostics = recordDiagnostics
            self.burstReferenceDNG = nil
            self.burstColorMatrix1 = nil
            self.burstColorMatrix2 = nil
            self.burstIlluminant1 = 17
            self.burstIlluminant2 = 21
            self.burstRotationAngle = 90
            if #available(iOS 17.0, *) {
                if let coordinator = self.rotationCoordinatorStorage as? AVCaptureDevice.RotationCoordinator {
                    let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                    let normalized = ((Int(angle.rounded()) % 360) + 360) % 360
                    if normalized % 90 == 0 {
                        self.burstRotationAngle = normalized
                    }
                }
            }
            self.burstStart = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                self.isCapturingBurst = true
                self.status = "Burst: travando exposicao..."
                self.lastCaptureNote = ""
                self.diagnosticNote = ""
            }
            self.prepareBurstExposure(generation: generation)
        }
    }

    private func prepareBurstExposure(generation: UUID, polls: Int = 0) {
        guard burstActive, burstGeneration == generation, let device = photoDevice else { return }
        let afterTap = CFAbsoluteTimeGetCurrent() - focusRequestedAt < 3
        let tapSettling = afterTap && (CFAbsoluteTimeGetCurrent() - focusRequestedAt < 0.25 || device.isAdjustingExposure)
        if device.isAdjustingFocus || tapSettling ||
           (burstConfig.mode != .photo && (device.isAdjustingExposure || device.isAdjustingWhiteBalance)) {
            guard polls < 30 else {
                abortBurst("A camera nao estabilizou foco/exposicao. Aponte para uma area com contraste e tente novamente.")
                return
            }
            sessionQueue.asyncAfter(deadline: .now() + 0.1) {
                self.prepareBurstExposure(generation: generation, polls: polls + 1)
            }
            return
        }
        guard let plan = BurstCapturePlan.make(mode: burstConfig.mode,
            previewDuration: CMTimeGetSeconds(device.exposureDuration), previewISO: Double(device.iso),
            minDuration: CMTimeGetSeconds(device.activeFormat.minExposureDuration),
            maxDuration: CMTimeGetSeconds(device.activeFormat.maxExposureDuration),
            minISO: Double(device.activeFormat.minISO), maxISO: Double(device.activeFormat.maxISO)) else {
            abortBurst("Limites de exposicao invalidos para esta captura.")
            return
        }
        if burstConfig.mode != .photo && !device.isExposureModeSupported(.custom) {
            abortBurst("Este formato nao permite controlar a exposicao para o modo de tripe.")
            return
        }
        burstPreview = latestPreview.flatMap {
            let age = CFAbsoluteTimeGetCurrent() - $0.timestamp
            return age >= 0 && age <= 0.75 && $0.timestamp >= focusRequestedAt ? $0 : nil
        }
        burstPlan = plan
        sessionQueue.asyncAfter(deadline: .now() + plan.timeoutSeconds) {
            if self.burstActive && self.burstGeneration == generation { self.abortBurst("Tempo limite da captura excedido.") }
        }
        let settleDelay = burstConfig.mode == .photo ? 0.4 : 2.0
        DispatchQueue.main.async {
            self.status = plan.config.mode == .photo ? "Preparando foto..." : "Mantenha o tripe parado; iniciando em 2 s..."
            self.lastCaptureNote = String(format: "%@ • %d fotos de %.3f s • ISO %.0f • %.2f s de luz planejados",
                                         plan.config.mode.title, plan.config.frameCount, plan.duration, plan.iso, plan.integrationSeconds)
        }
        do {
                try device.lockForConfiguration()
                self.savedCameraModes = (device.exposureMode, device.focusMode, device.whiteBalanceMode)
                self.savedFrameDurations = (device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration)
                let requested = CMTime(seconds: plan.duration, preferredTimescale: 1_000_000_000)
                let duration = CMTimeMaximum(CMTimeMinimum(requested, device.activeFormat.maxExposureDuration), device.activeFormat.minExposureDuration)
                let iso = min(max(Float(plan.iso), device.activeFormat.minISO), device.activeFormat.maxISO)
                self.burstLog.notice("burst start frames=\(self.burstConfig.frameCount, privacy: .public) iso=\(iso, privacy: .public) duration=\(CMTimeGetSeconds(duration), privacy: .public) ev=\(self.burstConfig.underExposureEV, privacy: .public) rotation=\(self.burstRotationAngle, privacy: .public)")
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                let canCustom = device.isExposureModeSupported(.custom)
                if canCustom {
                    device.setExposureModeCustom(duration: duration, iso: iso) { actual in
                        self.burstLog.notice("exposure settings synchronized at=\(CMTimeGetSeconds(actual), privacy: .public)")
                        self.sessionQueue.asyncAfter(deadline: .now() + settleDelay) {
                            guard self.burstGeneration == generation else { return }
                            self.captureBurstFrame()
                        }
                    }
                } else if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                device.unlockForConfiguration()
                if !canCustom {
                    self.sessionQueue.asyncAfter(deadline: .now() + settleDelay) {
                        guard self.burstGeneration == generation else { return }
                        self.captureBurstFrame()
                    }
                }
            } catch {
                self.abortBurst("Falha ao travar exposicao: \(error.localizedDescription)")
            }
    }

    private func captureBurstFrame() {
        guard burstActive, burstRemaining > 0 else { return }
        if burstConfig.mode != .photo {
            let wait = BurstFrameFreshness.tripodWait(elapsed: CFAbsoluteTimeGetCurrent() - burstLastRequestAt,
                                                     previousExposure: burstLastRequestDuration)
            if wait > 0 {
                let generation = burstGeneration
                sessionQueue.asyncAfter(deadline: .now() + wait) {
                    guard self.burstGeneration == generation else { return }
                    self.captureBurstFrame()
                }
                return
            }
        }
        guard session.isRunning else {
            abortBurst("Burst interrompido: sessao de camera parou.")
            return
        }
        if #available(iOS 17.0, *) {
            let readiness = photoOutput.captureReadiness
            if readiness != .ready {
                if burstReadinessPolls < 20 {
                    burstReadinessPolls += 1
                    burstLog.notice("output not ready readiness=\(String(describing: readiness), privacy: .public) poll=\(self.burstReadinessPolls, privacy: .public)")
                    let generation = burstGeneration
                    sessionQueue.asyncAfter(deadline: .now() + 0.1) {
                        guard self.burstGeneration == generation else { return }
                        self.captureBurstFrame()
                    }
                    return
                }
                abortBurst("Burst: camera nao ficou pronta (\(String(describing: readiness))).")
                return
            }
        }
        burstReadinessPolls = 0
        if let plan = burstPlan, let device = photoDevice {
            let index = burstFrames.count
            let wantsShort = plan.shortIndices.contains(index)
            if wantsShort != burstCurrentShort {
                let generation = burstGeneration
                do {
                    try device.lockForConfiguration()
                    let requested = CMTime(seconds: plan.duration(for: index), preferredTimescale: 1_000_000_000)
                    let duration = CMTimeMaximum(CMTimeMinimum(requested, device.activeFormat.maxExposureDuration), device.activeFormat.minExposureDuration)
                    let iso = min(max(Float(plan.iso), device.activeFormat.minISO), device.activeFormat.maxISO)
                    device.setExposureModeCustom(duration: duration, iso: iso) { _ in
                        self.sessionQueue.asyncAfter(deadline: .now() + 0.05) {
                            guard self.burstActive, self.burstGeneration == generation else { return }
                            self.burstCurrentShort = wantsShort
                            self.captureBurstFrame()
                        }
                    }
                    device.unlockForConfiguration()
                } catch { abortBurst("Falha ao mudar a exposicao HDR: \(error.localizedDescription)") }
                return
            }
        }
        let frameNumber = burstConfig.frameCount - burstRemaining + 1
        let modeTitle = burstConfig.mode.title
        let total = burstConfig.frameCount
        DispatchQueue.main.async { self.status = "\(modeTitle): capturando \(frameNumber)/\(total)..." }
        burstLog.notice("request frame \(frameNumber, privacy: .public)/\(self.burstConfig.frameCount, privacy: .public)")
        let settings = AVCapturePhotoSettings(rawPixelFormatType: burstFormat)
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
        burstLastRequestAt = CFAbsoluteTimeGetCurrent()
        burstLastRequestDuration = burstPlan?.duration(for: burstFrames.count) ?? 0
        submitPhoto(settings, kind: .burst)
    }

    private func handleBurstFrame(_ photo: AVCapturePhoto, error: Error?) {
        guard burstActive else { return }
        if let error {
            let nsError = error as NSError
            var detail = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                detail += " | causa \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
            }
            burstLog.notice("frame error \(detail, privacy: .public)")
            if burstRetries < 2 {
                burstRetries += 1
                let frame = burstConfig.frameCount - burstRemaining + 1
                DispatchQueue.main.async {
                    self.lastCaptureNote = "Burst: repetindo frame \(frame)/\(self.burstConfig.frameCount) (\(detail))"
                }
                let generation = burstGeneration
                sessionQueue.asyncAfter(deadline: .now() + 0.6) {
                    guard self.burstGeneration == generation else { return }
                    self.captureBurstFrame()
                }
                return
            }
            abortBurst("Burst interrompido (frame \(burstConfig.frameCount - burstRemaining + 1)): \(detail)")
            return
        }
        burstRetries = 0
        if burstFrames.isEmpty {
            self.captureBurstCalibration(from: photo)
            if burstRecordDiagnostics {
                burstReferenceDNG = photo.fileDataRepresentation()
            }
        }
        guard let pixelBuffer = photo.pixelBuffer else {
            abortBurst("Burst sem pixel buffer RAW.")
            return
        }
        guard let frame = makeBurstFrame(from: pixelBuffer) else {
            abortBurst("Burst: falha ao copiar frame RAW.")
            return
        }
        let timestamp = CMTimeGetSeconds(photo.timestamp)
        do {
            let fresh = try burstFreshness.accept(frame, timestamp: timestamp)
            if !fresh {
                burstDuplicateRetries += 1
                guard burstDuplicateRetries <= 3 else {
                    abortBurst("A camera repetiu RAWs; captura cancelada para evitar empilhar imagens iguais.")
                    return
                }
                burstLog.notice("repeated/stale RAW rejected, total=\(self.burstFreshness.rejectedCount, privacy: .public)")
                DispatchQueue.main.async { self.status = "Aguardando uma nova exposicao…" }
                let generation = burstGeneration
                sessionQueue.asyncAfter(deadline: .now() + max(burstLastRequestDuration, 0.1)) {
                    guard self.burstGeneration == generation else { return }
                    self.captureBurstFrame()
                }
                return
            }
        } catch {
            abortBurst("RAW sem identidade/timestamp valido; captura cancelada.")
            return
        }
        burstDuplicateRetries = 0
        if burstFrames.isEmpty, burstConfig.mode == .night,
           BurstHDR.highlightFraction(frame) >= 0.0005 {
            burstPlan?.bracketsHighlights = true
            burstLog.notice("HDR highlight bracket enabled from first RAW")
        }
        burstFrames.append(frame)
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var reading: [String: Double] = ["frame_index": Double(burstExposureReadings.count)]
        reading["photo_timestamp_seconds"] = timestamp
        reading["highlight_frame"] = burstCurrentShort ? 1 : 0
        if let seconds = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber,
           seconds.doubleValue.isFinite, seconds.doubleValue > 0 { reading["duration_seconds"] = seconds.doubleValue }
        if let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let iso = values.first,
           iso.doubleValue.isFinite, iso.doubleValue > 0 { reading["iso"] = iso.doubleValue }
        burstExposureReadings.append(reading)
        burstRemaining -= 1
        let captured = burstConfig.frameCount - burstRemaining
        burstLog.notice("frame \(captured, privacy: .public)/\(self.burstConfig.frameCount, privacy: .public) received \(frame.data.count, privacy: .public) bytes")
        DispatchQueue.main.async { self.lastCaptureNote = "Burst: \(captured)/\(self.burstConfig.frameCount)" }
        if burstRemaining > 0 {
            captureBurstFrame()
        } else {
            finishBurst()
        }
    }

    private func captureBurstCalibration(from photo: AVCapturePhoto) {
        let dngKey = kCGImagePropertyDNGDictionary as String
        let dng = photo.metadata[dngKey] as? [String: Any] ?? [:]
        if let profile = dng["NoiseProfile"] as? [NSNumber] {
            let values = profile.map { $0.doubleValue }
            if values.count == 2, values.allSatisfy({ $0.isFinite && $0 >= 0 }) {
                burstNoiseProfile = values
            }
        }
        burstLog.notice("noise profile present=\(self.burstNoiseProfile != nil, privacy: .public)")
        if dng.isEmpty {
            burstLog.notice("dng metadata ausente no primeiro frame")
            return
        }
        if let neutral = dng[kCGImagePropertyDNGAsShotNeutral as String] as? [Any] {
            let values = neutral.compactMap { ($0 as? NSNumber)?.doubleValue }
            if values.count == 3, values.allSatisfy({ $0 > 0 }) {
                burstAsShotNeutral = values
                let text = values.map { String(format: "%.4f", $0) }.joined(separator: ",")
                burstLog.notice("as shot neutral \(text, privacy: .public)")
            }
        }
        func readMatrix(_ key: String) -> [Double]? {
            guard let matrix = dng[key] as? [Any] else { return nil }
            let values = matrix.compactMap { ($0 as? NSNumber)?.doubleValue }
            return values.count == 9 ? values : nil
        }
        let cm1 = readMatrix(kCGImagePropertyDNGColorMatrix1 as String)
        let cm2 = readMatrix(kCGImagePropertyDNGColorMatrix2 as String)
        if let cm1 {
            burstLog.notice("color matrix1 \(cm1.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public)")
        }
        if let cm2 {
            burstLog.notice("color matrix2 \(cm2.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public)")
        }
        let illuminant1 = (dng[kCGImagePropertyDNGCalibrationIlluminant1 as String] as? NSNumber)?.intValue ?? 0
        let illuminant2 = (dng[kCGImagePropertyDNGCalibrationIlluminant2 as String] as? NSNumber)?.intValue ?? 0
        if illuminant1 > 0 || illuminant2 > 0 {
            burstLog.notice("ill1=\(illuminant1, privacy: .public) ill2=\(illuminant2, privacy: .public)")
        }
        burstColorMatrix1 = cm1 ?? cm2
        burstColorMatrix2 = cm2 ?? cm1
        burstIlluminant1 = illuminant1 > 0 ? illuminant1 : 17
        burstIlluminant2 = illuminant2 > 0 ? illuminant2 : 21
        if burstColorMatrix1 == nil || burstColorMatrix2 == nil {
            burstLog.notice("matriz de cor ausente no dng")
        }
    }

    private func makeBurstFrame(from buffer: CVPixelBuffer) -> BurstFrame? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == 0 else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_14Bayer_RGGB,
              BurstRawLayout.isValid(width: width, height: height,
                                     bytesPerRow: bytesPerRow, byteCount: CVPixelBufferGetDataSize(buffer)),
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let data = Data(bytes: UnsafeRawPointer(base), count: bytesPerRow * height)
        return BurstFrame(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    private func finishBurst() {
        let frames = burstFrames
        let config = burstConfig
        let plan = burstPlan
        let exposureReadings = burstExposureReadings
        let frameHashes = burstFreshness.hashes
        let duplicateRejections = burstFreshness.rejectedCount
        let highlightFrames = plan?.shortIndices ?? []
        let exposureProducts: [Double]? = exposureReadings.allSatisfy({ $0["duration_seconds"] != nil && $0["iso"] != nil })
            ? exposureReadings.map { ($0["duration_seconds"] ?? 0) * ($0["iso"] ?? 0) } : nil
        let rotationAngle = burstRotationAngle
        let asShotNeutral = burstAsShotNeutral
        let noiseProfile = burstNoiseProfile
        let recordDiagnostics = burstRecordDiagnostics
        let referenceDNG = burstReferenceDNG
        let preview = burstPreview
        burstPreview = nil
        burstReferenceDNG = nil
        let matrix1 = burstColorMatrix1
        let matrix2 = burstColorMatrix2
        let temperature1 = BurstColorMatrix.temperature(forIlluminant: burstIlluminant1) ?? 2856
        let temperature2 = BurstColorMatrix.temperature(forIlluminant: burstIlluminant2) ?? 6504
        var colorTransform: [Double]?
        if let matrix1, let matrix2, let asShotNeutral {
            colorTransform = BurstColorMatrix.cameraToSRGB(
                matrix1: matrix1,
                matrix2: matrix2,
                neutral: asShotNeutral,
                temperature1: temperature1,
                temperature2: temperature2
            )
        }
        if let colorTransform {
            let text = colorTransform.map { String(format: "%.4f", $0) }.joined(separator: ",")
            burstLog.notice("camera to sRGB \(text, privacy: .public)")
        } else {
            burstLog.notice("camera to sRGB indisponivel; usando gray-world")
        }
        burstFrames.removeAll()
        burstActive = false
        processingActive = true
        restoreCameraModes()
        burstLog.notice("capture done frames=\(frames.count, privacy: .public) elapsed=\(CFAbsoluteTimeGetCurrent() - self.burstStart, privacy: .public)")
        DispatchQueue.main.async {
            self.status = "Processando burst..."
            self.lastCaptureNote = "Burst: \(frames.count) frames, alinhando e combinando..."
        }
        processingQueue.async {
            var diagnosticDirectory: URL?
            if recordDiagnostics {
                do {
                    let directory = try BurstDiagnostics.save(frames: frames, referenceDNG: referenceDNG,
                                                              rotation: rotationAngle, neutral: asShotNeutral,
                                                              transform: colorTransform, config: config, plan: plan,
                                                              exposureReadings: exposureReadings, preview: preview,
                                                              frameHashes: frameHashes, duplicateRejections: duplicateRejections)
                    diagnosticDirectory = directory
                    DispatchQueue.main.async {
                        self.diagnosticNote = "Um ensaio guardado por ate 24 horas. A proxima captura normal nao guarda RAWs."
                    }
                } catch {
                    DispatchQueue.main.async { self.diagnosticNote = "Falha ao salvar ensaio: \(error.localizedDescription)" }
                }
            }
            do {
                let result = try BurstProcessor.process(
                    frames: frames,
                    underExposureEV: config.underExposureEV,
                    rotationAngle: rotationAngle,
                    asShotNeutral: asShotNeutral,
                    colorTransform: colorTransform,
                    noiseProfile: noiseProfile,
                    usesRobustMerge: config.usesRobustMerge,
                    highlightFrames: highlightFrames, exposureProducts: exposureProducts,
                    previewReference: preview?.reference
                )
                if let directory = diagnosticDirectory {
                    do {
                        try BurstDiagnostics.saveProcessing(result, directory: directory, noiseProfile: noiseProfile)
                    } catch {
                        self.burstLog.notice("processing report failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                self.saveBurst(result)
            } catch {
                self.completeBurstProcessing()
                self.burstLog.notice("process error \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.status = "Falha no burst"
                    self.lastCaptureNote = "Erro: \(error.localizedDescription)"
                }
            }
            self.refreshDiagnosticStorage()
        }
    }

    private func restoreCameraModes() {
        guard let device = photoDevice, let saved = savedCameraModes else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(saved.exposure) {
                device.exposureMode = saved.exposure
            }
            if device.isFocusModeSupported(saved.focus) {
                device.focusMode = saved.focus
            }
            if device.isWhiteBalanceModeSupported(saved.whiteBalance) {
                device.whiteBalanceMode = saved.whiteBalance
            }
            // Custom long shutters can lengthen the preview frame durations.
            // Restore their original range after returning exposure to AE.
            if let durations = savedFrameDurations,
               CMTimeCompare(durations.min, device.activeVideoMinFrameDuration) != 0 || CMTimeCompare(durations.max, device.activeVideoMaxFrameDuration) != 0 {
                if CMTimeCompare(durations.min, device.activeVideoMaxFrameDuration) > 0 {
                    device.activeVideoMaxFrameDuration = durations.max
                    device.activeVideoMinFrameDuration = durations.min
                } else {
                    device.activeVideoMinFrameDuration = durations.min
                    device.activeVideoMaxFrameDuration = durations.max
                }
            }
            device.unlockForConfiguration()
            savedCameraModes = nil
            savedFrameDurations = nil
        } catch {
            burstLog.error("Falha ao restaurar modos da camera: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func abortBurst(_ message: String) {
        burstLog.notice("abort \(message, privacy: .public)")
        burstActive = false
        burstGeneration = UUID()
        requests = requests.filter { $0.value != .burst }
        burstFrames.removeAll()
        burstReferenceDNG = nil
        burstPreview = nil
        restoreCameraModes()
        DispatchQueue.main.async {
            self.isCapturingBurst = false
            self.status = "Burst cancelado"
            self.lastCaptureNote = message
        }
    }

    private func completeBurstProcessing() {
        sessionQueue.async {
            self.processingActive = false
            DispatchQueue.main.async { self.isCapturingBurst = false }
        }
    }

    private func saveBurst(_ result: BurstProcessResult) {
        let megabytes = Double(result.jpegData.count) / 1_048_576
        let shifts = result.shifts.dropFirst().map { "(\($0.dx),\($0.dy))" }.joined(separator: " ")
        let shiftText = shifts.isEmpty ? "0" : shifts
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.completeBurstProcessing()
                DispatchQueue.main.async {
                    self.status = "Burst processado"
                    self.lastCaptureNote = "Permissao de fototeca negada."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: result.jpegData, options: nil)
            } completionHandler: { success, error in
                self.completeBurstProcessing()
                DispatchQueue.main.async {
                if success {
                    self.lastPhotoData = result.jpegData
                    self.lastPhotoThumbnail = UIImage(data: result.jpegData)?.preparingThumbnail(of: CGSize(width: 180, height: 180))
                    self.status = "Burst pronto"
                    self.lastCaptureNote = String(
                        format: "Burst %d frames %dx%d: %.1f MB | proc %.1fs | WB R %.2f | exp %.2f | desloc %@",
                        result.frameCount, result.width, result.height, megabytes,
                        result.elapsedSeconds, result.whiteGain, result.exposureScale,
                        shiftText
                    )
                    self.burstLog.notice("saved \(result.jpegData.count, privacy: .public) bytes proc=\(result.elapsedSeconds, privacy: .public) scale=\(result.exposureScale, privacy: .public) wbR=\(result.whiteGain, privacy: .public) wbB=\(result.blueGain, privacy: .public) ccm=\(result.usedCCM ? 1 : 0, privacy: .public) dn=\(result.denoised ? 1 : 0, privacy: .public) shifts=\(shiftText, privacy: .public)")
                } else {
                        self.status = "Falha ao salvar"
                        self.lastCaptureNote = "Burst: \(error?.localizedDescription ?? "erro desconhecido")"
                    }
                }
            }
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "desconhecida"
        }
    }

    private func submitPhoto(_ settings: AVCapturePhotoSettings, kind: CaptureRequest) {
        let id = settings.uniqueID
        requests[id] = kind
        photoOutput.capturePhoto(with: settings, delegate: self)
        sessionQueue.asyncAfter(deadline: .now() + 10) {
            guard let pending = self.requests.removeValue(forKey: id) else { return }
            switch pending {
            case .burst: self.abortBurst("Tempo limite aguardando frame RAW.")
            case .probe: self.finishRawProbe(status: "Tempo limite aguardando RAW.")
            case .photo:
                self.singleCaptureActive = false
                DispatchQueue.main.async { self.lastCaptureNote = "Tempo limite aguardando foto." }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        sessionQueue.async {
            guard let kind = self.requests.removeValue(forKey: resolvedSettings.uniqueID) else { return }
            switch kind {
            case .burst: self.abortBurst("Falha de captura: \(error.localizedDescription)")
            case .probe: self.finishRawProbe(status: "Falha de captura: \(error.localizedDescription)")
            case .photo:
                self.singleCaptureActive = false
                DispatchQueue.main.async { self.lastCaptureNote = "Falha: \(error.localizedDescription)" }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        sessionQueue.async {
            guard let kind = self.requests.removeValue(forKey: photo.resolvedSettings.uniqueID) else { return }
            switch kind {
            case .probe: self.handleRawProbeFrame(photo, error: error)
            case .burst: self.handleBurstFrame(photo, error: error)
            case .photo:
                self.singleCaptureActive = false
                self.saveSinglePhoto(photo, error: error)
            }
        }
    }

    private func saveSinglePhoto(_ photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.lastCaptureNote = "Falha: \(error.localizedDescription)" }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.lastCaptureNote = "Sem dados da foto." }
            return
        }
        let megabytes = Double(data.count) / 1_048_576
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.lastCaptureNote = "Permissao de fototeca negada." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.lastPhotoData = data
                        self.lastPhotoThumbnail = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 180, height: 180))
                        self.lastCaptureNote = String(format: "Capturada: %.1f MB", megabytes)
                    } else {
                        self.lastCaptureNote = "Falha ao salvar: \(error?.localizedDescription ?? "desconhecida")"
                    }
                }
            }
        }
    }
}
