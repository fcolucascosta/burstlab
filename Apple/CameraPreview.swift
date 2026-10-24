import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var allowsFocus = true
    var onFocus: ((CGPoint, @escaping (Bool) -> Void) -> Void)?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.allowsFocus = allowsFocus
        view.onFocus = onFocus
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.allowsFocus = allowsFocus
        uiView.onFocus = onFocus
    }
}

final class PreviewContainerView: UIView {
    var allowsFocus = true
    var onFocus: ((CGPoint, @escaping (Bool) -> Void) -> Void)?
    private let focusMarker = CAShapeLayer()
    private var focusGeneration = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:))))
        focusMarker.bounds = CGRect(x: 0, y: 0, width: 68, height: 68)
        focusMarker.path = UIBezierPath(rect: focusMarker.bounds.insetBy(dx: 1, dy: 1)).cgPath
        focusMarker.strokeColor = UIColor.systemYellow.cgColor
        focusMarker.fillColor = UIColor.clear.cgColor
        focusMarker.lineWidth = 1.5
        focusMarker.opacity = 0
        layer.addSublayer(focusMarker)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func focusTapped(_ gesture: UITapGestureRecognizer) {
        guard allowsFocus, let onFocus else { return }
        let location = gesture.location(in: self)
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        let generation = UUID()
        focusGeneration = generation
        focusMarker.removeAllAnimations()
        focusMarker.position = location
        focusMarker.strokeColor = UIColor.systemYellow.cgColor
        focusMarker.opacity = 1
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.3; animation.toValue = 1; animation.duration = 0.2
        focusMarker.add(animation, forKey: "focus")
        onFocus(point) { [weak self] accepted in
            DispatchQueue.main.async {
                guard let self, self.focusGeneration == generation else { return }
                self.focusMarker.strokeColor = (accepted ? UIColor.systemYellow : UIColor.systemRed).cgColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard self.focusGeneration == generation else { return }
                    CATransaction.begin(); CATransaction.setAnimationDuration(0.3)
                    self.focusMarker.opacity = 0
                    CATransaction.commit()
                }
            }
        }
    }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
