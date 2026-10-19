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
        lines.append(String(format: "Exposicao: %.4fs a %.4fs", minExposureSeconds, maxExposureSeconds))
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

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "dev.lucas.burstlab.session")
    private var photoDevice: AVCaptureDevice?
    private var configured = false

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
            guard self.configured else {
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

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
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
