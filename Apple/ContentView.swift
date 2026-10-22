import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var showReport = false
    @AppStorage("recordDiagnostics") private var recordDiagnostics = false
    @AppStorage("captureMode") private var captureMode = CaptureMode.photo.rawValue

    private var selectedMode: CaptureMode { CaptureMode(rawValue: captureMode) ?? .photo }
    private var busy: Bool { !camera.isConfigured || camera.isProbingRaw || camera.isCapturingBurst }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if !targetEnvironment(simulator)
            CameraPreview(session: camera.session).ignoresSafeArea()
            #endif
            VStack(spacing: 12) {
                HStack {
                    Text("BurstLab \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                    Spacer()
                    Button {
                        showReport = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Relatorio de capacidades")
                }
                .padding(.horizontal)
                Spacer()
                Text(camera.status)
                    .font(.footnote)
                    .foregroundStyle(.white)
                Text(camera.lastCaptureNote)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                Picker("Modo", selection: $captureMode) {
                    ForEach(CaptureMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 28)
                .disabled(busy)
                Group {
                    switch selectedMode {
                    case .photo: Text("Para fotografar na mao.")
                    case .night: Text("Use tripe. HDR automatico para preservar luzes e sombras.")
                    case .longExposure: Text("Use tripe. O movimento deixa rastros de longa exposicao.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white)
                Button {
                    camera.captureBurst(mode: selectedMode, recordDiagnostics: recordDiagnostics)
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
                .disabled(busy)
                .opacity(camera.isConfigured ? 1 : 0.4)
                .accessibilityLabel("Capturar \(selectedMode.title)")
                Button("Foto de referencia") { camera.capturePhoto() }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .disabled(busy)
            }
            .padding(.vertical, 24)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showReport) {
            CapabilityReportView(capabilities: camera.capabilities, rawProbe: camera.rawProbeReport,
                                 fallback: camera.status, diagnosticNote: camera.diagnosticNote,
                                 recordDiagnostics: $recordDiagnostics, canProbe: !busy,
                                 onProbe: { camera.probeRawBurst() })
        }
    }
}

struct CapabilityReportView: View {
    @Environment(\.dismiss) private var dismiss
    let capabilities: CaptureCapabilities?
    let rawProbe: String?
    let fallback: String
    let diagnosticNote: String
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
                    Text(reportText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Capacidades")
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
