import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var showReport = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if !targetEnvironment(simulator)
            CameraPreview(session: camera.session).ignoresSafeArea()
            #endif
            VStack(spacing: 12) {
                HStack {
                    Text("BurstLab 0.1.0")
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
                Button {
                    camera.capturePhoto()
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
                .disabled(!camera.isConfigured)
                .opacity(camera.isConfigured ? 1 : 0.4)
                .accessibilityLabel("Capturar foto")
            }
            .padding(.vertical, 24)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showReport) {
            CapabilityReportView(capabilities: camera.capabilities, fallback: camera.status)
        }
    }
}

struct CapabilityReportView: View {
    @Environment(\.dismiss) private var dismiss
    let capabilities: CaptureCapabilities?
    let fallback: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(capabilities?.report ?? fallback)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        if let report = capabilities?.report {
                            UIPasteboard.general.string = report
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(capabilities == nil)
                    .accessibilityLabel("Copiar relatorio")
                }
            }
        }
    }
}
