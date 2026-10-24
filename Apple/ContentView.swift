import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var showReport = false
    @State private var showPhoto = false
    @AppStorage("showGrid") private var showGrid = false
    @AppStorage("recordDiagnostics") private var recordDiagnostics = false
    @AppStorage("captureMode") private var captureMode = CaptureMode.photo.rawValue

    private var selectedMode: CaptureMode { CaptureMode(rawValue: captureMode) ?? .photo }
    private var busy: Bool { !camera.isConfigured || camera.isProbingRaw || camera.isCapturingBurst }

    var body: some View {
        VStack(spacing: 0) {
            cameraToolbar
            GeometryReader { geometry in
                let width = min(geometry.size.width, geometry.size.height * 0.75)
                ZStack {
                    #if !targetEnvironment(simulator)
                    CameraPreview(session: camera.session, allowsFocus: !busy) { point, completion in
                        camera.focus(at: point, completion: completion)
                    }
                    #else
                    Color(white: 0.12)
                    Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.gray)
                    #endif
                    if showGrid { CameraThirdsGrid().allowsHitTesting(false) }
                }
                .frame(width: width, height: width / 0.75)
                .clipped()
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            cameraControls
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showReport) {
            CapabilityReportView(capabilities: camera.capabilities, rawProbe: camera.rawProbeReport,
                                 fallback: camera.status, diagnosticNote: camera.diagnosticNote,
                                 captureNote: camera.lastCaptureNote,
                                 recordDiagnostics: $recordDiagnostics, canProbe: !busy,
                                 onProbe: { camera.probeRawBurst() })
        }
        .sheet(isPresented: $showPhoto) {
            CapturedPhotoView(data: camera.lastPhotoData)
        }
    }

    private var cameraToolbar: some View {
        HStack {
            Button { showGrid.toggle() } label: {
                Image(systemName: "grid").foregroundStyle(showGrid ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(showGrid ? "Ocultar grade" : "Mostrar grade")
            Spacer()
            Text("BURSTLAB").font(.system(size: 12, weight: .semibold)).tracking(2)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button { showReport = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Ajustes")
        }
        .font(.system(size: 18))
        .padding(.horizontal, 12)
    }

    private var modeHint: String {
        switch selectedMode {
        case .photo: return "Toque na imagem para focar"
        case .night: return "Use tripe · Mantenha a cena parada"
        case .longExposure: return "Use tripe · Movimento cria rastros"
        }
    }

    private var cameraControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 28) {
                ForEach(CaptureMode.allCases, id: \.rawValue) { mode in
                    Button { captureMode = mode.rawValue } label: {
                        Text(mode.title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1)
                            .foregroundStyle(selectedMode == mode ? .yellow : .white.opacity(0.6))
                            .padding(.vertical, 10)
                    }
                    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                }
            }
            .disabled(busy)
            HStack {
                Button { showPhoto = true } label: {
                    Group {
                        if let thumbnail = camera.lastPhotoThumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").font(.title2).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(width: 48, height: 48).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(camera.lastPhotoThumbnail == nil)
                .accessibilityLabel("Ver ultima foto")
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.captureBurst(mode: selectedMode, recordDiagnostics: recordDiagnostics)
                } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(busy ? 0.4 : 1), lineWidth: 3).frame(width: 78, height: 78)
                        if busy {
                            ProgressView().tint(.yellow).scaleEffect(1.4)
                        } else {
                            Circle().fill(.white).frame(width: 66, height: 66)
                        }
                    }
                }
                .disabled(busy)
                .accessibilityLabel("Capturar \(selectedMode.title)")
                Spacer()
                Button { camera.capturePhoto() } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "camera.badge.ellipsis").font(.title2)
                        Text("Referencia").font(.system(size: 9))
                    }.frame(width: 58)
                }
                .disabled(busy)
                .accessibilityLabel("Capturar foto de referencia pelo sistema")
            }
            .padding(.horizontal, 30)
            Text(busy ? camera.status : (camera.focusHint.isEmpty ? modeHint : camera.focusHint))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                .lineLimit(2).multilineTextAlignment(.center).frame(height: 28)
                .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

private struct CameraThirdsGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    let x = geometry.size.width * fraction, y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }.stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

private struct CapturedPhotoView: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data?
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .navigationTitle("Ultima foto").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}

struct CapabilityReportView: View {
    @Environment(\.dismiss) private var dismiss
    let capabilities: CaptureCapabilities?
    let rawProbe: String?
    let fallback: String
    let diagnosticNote: String
    let captureNote: String
    @Binding var recordDiagnostics: Bool
    let canProbe: Bool
    let onProbe: () -> Void

    private var reportText: String {
        var parts: [String] = []
        if let capabilities {
            parts.append(capabilities.report)
        } else {
            parts.append(fallback)
        }
        if let rawProbe {
            parts.append("=== Burst RAW ===\n" + rawProbe)
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Guardar RAWs para comparacao", isOn: $recordDiagnostics)
                    Text("Opcional: guarda cerca de 220 MB em Foto ou 420 MB em Noite/Longa em Arquivos > No Meu iPhone > BurstLab > Ensaios. A foto continua sendo salva na fototeca. Apague os ensaios depois de copiar para o computador.")
                        .font(.caption)
                    Button("Sonda de diagnostico RAW", action: onProbe).disabled(!canProbe)
                    if !diagnosticNote.isEmpty { Text(diagnosticNote).font(.caption) }
                    if !captureNote.isEmpty { Text(captureNote).font(.caption.monospaced()) }
                    Text("BurstLab \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(reportText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        UIPasteboard.general.string = reportText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(capabilities == nil && rawProbe == nil)
                    .accessibilityLabel("Copiar relatorio")
                }
            }
        }
    }
}
