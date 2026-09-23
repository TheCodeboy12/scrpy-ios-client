import SwiftUI
#if canImport(UIKit)
import UIKit
import AVFoundation

public final class TouchOverlayView: UIView {
    public weak var session: ScrcpyClient?

    private var activeTouches = [UITouch: UInt64]()
    private var nextPointerId: UInt64 = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    private func sendTouchEvent(for touch: UITouch, action: AndroidMotionEventAction) {
        guard let session = session, let videoSize = session.videoDimensions else { return }

        // Find or assign pointerId
        let pointerId: UInt64
        if let existing = activeTouches[touch] {
            pointerId = existing
        } else {
            pointerId = nextPointerId
            nextPointerId = (nextPointerId + 1) % 10
            activeTouches[touch] = pointerId
        }

        let loc = touch.location(in: self)
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard rect.width > 0 && rect.height > 0 else { return }

        // Clamp to video display rect
        let clampedX = max(rect.origin.x, min(rect.origin.x + rect.width, loc.x))
        let clampedY = max(rect.origin.y, min(rect.origin.y + rect.height, loc.y))

        let normX = (clampedX - rect.origin.x) / rect.width
        let normY = (clampedY - rect.origin.y) / rect.height

        let devX = Int32(normX * Double(videoSize.width))
        let devY = Int32(normY * Double(videoSize.height))

        let pressure = Float(touch.force > 0 ? touch.force / touch.maximumPossibleForce : 1.0)

        session.send(controlMessage: .injectTouchEvent(
            action: action,
            pointerId: pointerId,
            x: devX,
            y: devY,
            screenWidth: UInt16(videoSize.width),
            screenHeight: UInt16(videoSize.height),
            pressure: pressure
        ))

        if action == .up || action == .cancel {
            activeTouches.removeValue(forKey: touch)
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            sendTouchEvent(for: touch, action: .down)
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            sendTouchEvent(for: touch, action: .move)
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            sendTouchEvent(for: touch, action: .up)
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            sendTouchEvent(for: touch, action: .cancel)
        }
    }
}

public struct TouchOverlayRepresentable: UIViewRepresentable {
    @ObservedObject public var session: ScrcpyClient

    public init(session: ScrcpyClient) {
        self.session = session
    }

    public func makeUIView(context: Context) -> TouchOverlayView {
        let view = TouchOverlayView()
        view.session = session
        return view
    }

    public func updateUIView(_ uiView: TouchOverlayView, context: Context) {
        uiView.session = session
    }
}
#endif
