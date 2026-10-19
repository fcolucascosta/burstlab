import AVFoundation
import Photos
import UIKit

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

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "dev.lucas.burstlab.session")
    private var photoDevice: AVCaptureDevice?
    private var configured = false
    private var probeActive = false
    private var probeRemaining = 0
    private var probeLines: [String] = []
    private var probeStart: CFTimeInterval = 0
    private var probeIntervalStart: CFTimeInterval?
    private var calibrationBuffer: CVPixelBuffer?

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
                DispatchQueue.main.async { self.isConfigured = self.configured }
                self.publishCapabilities()
            }
        }
        #endif
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async {
            guard self.configured, self.session.isRunning, !self.probeActive else {
                DispatchQueue.main.async { self.status = "Sessao de camera indisponivel." }
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
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
            guard self.configured, self.session.isRunning, !self.probeActive else { return }
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
        photoOutput.capturePhoto(with: settings, delegate: self)
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

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "desconhecida"
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if probeActive {
            sessionQueue.async { self.handleRawProbeFrame(photo, error: error) }
            return
        }
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
