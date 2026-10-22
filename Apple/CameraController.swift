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

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var status = "Iniciando..."
    @Published var capabilities: CaptureCapabilities?
    @Published var lastCaptureNote = ""
    @Published var isConfigured = false
    @Published var isProbingRaw = false
    @Published var rawProbeReport: String?
    @Published var isCapturingBurst = false

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
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
    private var burstActive = false
    private var burstFrames: [BurstFrame] = []
    private var burstRemaining = 0
    private var burstFormat: OSType = 0
    private var burstStart: CFTimeInterval = 0
    private var burstConfig = BurstConfig.defaults(for: .photo)
    private var burstRetries = 0
    private var burstReadinessPolls = 0
    private var burstRotationAngle = 90
    private var burstAsShotNeutral: [Double]?
    private var burstColorMatrix1: [Double]?
    private var burstColorMatrix2: [Double]?
    private var burstIlluminant1 = 17
    private var burstIlluminant2 = 21
    private var rotationCoordinatorStorage: Any?

    func start() {
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
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
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
        session.commitConfiguration()
        configured = true
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

    func captureBurst() {
        sessionQueue.async {
            self.burstLog.notice("captureBurst configured=\(self.configured, privacy: .public) running=\(self.session.isRunning, privacy: .public) probe=\(self.probeActive, privacy: .public) burst=\(self.burstActive, privacy: .public)")
            guard self.configured, self.session.isRunning, !self.probeActive, !self.burstActive, !self.processingActive, !self.singleCaptureActive else { return }
            guard self.photoOutput.availableRawPhotoPixelFormatTypes.contains(kCVPixelFormatType_14Bayer_RGGB) else {
                DispatchQueue.main.async { self.lastCaptureNote = "Burst requer RAW Bayer RGGB de 14 bits calibrado para este aparelho." }
                return
            }
            let rawFormat = kCVPixelFormatType_14Bayer_RGGB
            guard let device = self.photoDevice else { return }
            self.burstConfig = BurstConfig.defaults(for: .photo)
            self.burstActive = true
            self.burstGeneration = UUID()
            let generation = self.burstGeneration
            self.sessionQueue.asyncAfter(deadline: .now() + 15) {
                if self.burstActive && self.burstGeneration == generation {
                    self.abortBurst("Tempo limite do burst excedido.")
                }
            }
            self.burstFormat = rawFormat
            self.burstFrames.removeAll()
            self.burstRemaining = self.burstConfig.frameCount
            self.burstRetries = 0
            self.burstReadinessPolls = 0
            self.burstAsShotNeutral = nil
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
            }
            do {
                try device.lockForConfiguration()
                self.savedCameraModes = (device.exposureMode, device.focusMode, device.whiteBalanceMode)
                let factor = pow(2.0, self.burstConfig.underExposureEV)
                let scaled = CMTimeMultiplyByFloat64(device.exposureDuration, multiplier: factor)
                let duration = CMTimeMaximum(CMTimeMinimum(scaled, device.activeFormat.maxExposureDuration), device.activeFormat.minExposureDuration)
                let iso = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
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
                        self.burstLog.notice("exposure settled value=\(actual.value, privacy: .public) timescale=\(actual.timescale, privacy: .public) seconds=\(CMTimeGetSeconds(actual), privacy: .public)")
                        self.sessionQueue.asyncAfter(deadline: .now() + 0.4) {
                            guard self.burstGeneration == generation else { return }
                            self.captureBurstFrame()
                        }
                    }
                } else if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                device.unlockForConfiguration()
                if !canCustom {
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.4) {
                        guard self.burstGeneration == generation else { return }
                        self.captureBurstFrame()
                    }
                }
            } catch {
                self.abortBurst("Falha ao travar exposicao: \(error.localizedDescription)")
            }
        }
    }

    private func captureBurstFrame() {
        guard burstActive, burstRemaining > 0 else { return }
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
        let frameNumber = burstConfig.frameCount - burstRemaining + 1
        burstLog.notice("request frame \(frameNumber, privacy: .public)/\(self.burstConfig.frameCount, privacy: .public)")
        let settings = AVCapturePhotoSettings(rawPixelFormatType: burstFormat)
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
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
        }
        guard let pixelBuffer = photo.pixelBuffer else {
            abortBurst("Burst sem pixel buffer RAW.")
            return
        }
        guard let frame = makeBurstFrame(from: pixelBuffer) else {
            abortBurst("Burst: falha ao copiar frame RAW.")
            return
        }
        burstFrames.append(frame)
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
        let rotationAngle = burstRotationAngle
        let asShotNeutral = burstAsShotNeutral
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
            do {
                let result = try BurstProcessor.process(
                    frames: frames,
                    underExposureEV: config.underExposureEV,
                    rotationAngle: rotationAngle,
                    asShotNeutral: asShotNeutral,
                    colorTransform: colorTransform
                )
                self.saveBurst(result)
            } catch {
                self.completeBurstProcessing()
                self.burstLog.notice("process error \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.status = "Falha no burst"
                    self.lastCaptureNote = "Erro: \(error.localizedDescription)"
                }
            }
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
            device.unlockForConfiguration()
            savedCameraModes = nil
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
                        self.lastCaptureNote = String(format: "Capturada: %.1f MB", megabytes)
                    } else {
                        self.lastCaptureNote = "Falha ao salvar: \(error?.localizedDescription ?? "desconhecida")"
                    }
                }
            }
        }
    }
}
