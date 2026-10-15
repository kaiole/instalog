import SwiftUI
import UIKit

extension View {
    /// A sideways swipe that only takes the touch when the movement is clearly horizontal, so
    /// vertical and diagonal drags keep scrolling. `onChanged` gets the horizontal translation;
    /// `onEnded` gets the final one, or 0 if the swipe was cancelled.
    func horizontalSwipe(
        isEnabled: Bool = true, onChanged: @escaping (CGFloat) -> Void = { _ in },
        onEnded: @escaping (CGFloat) -> Void
    ) -> some View {
        modifier(HorizontalSwipeModifier(isEnabled: isEnabled, onChanged: onChanged, onEnded: onEnded))
    }
}

private struct HorizontalSwipeModifier: ViewModifier {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(HorizontalPan(isEnabled: isEnabled, onChanged: onChanged, onEnded: onEnded))
        } else {
            // SwiftUI can't decline a drag by direction, so iOS 17 settles for a longer start
            // distance and ignores mostly-vertical movement.
            content.simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard isEnabled, abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                        onChanged(value.translation.width)
                    }
                    .onEnded { value in
                        guard isEnabled, abs(value.translation.width) > abs(value.translation.height) * 2 else { return onEnded(0) }
                        onEnded(value.translation.width)
                    },
                including: isEnabled ? .all : .subviews)
        }
    }
}

/// A UIKit pan that refuses to begin unless horizontal speed clearly beats vertical, the way
/// table-row swipe actions decide. When it declines, the scroll view gets the touch.
@available(iOS 18.0, *)
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .began, .changed: onChanged(dx)
        case .ended: onEnded(dx)
        case .cancelled, .failed: onEnded(0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let translation = pan.translation(in: pan.view)
            // Velocity is the better signal; a slow, deliberate drag falls back to distance.
            let horizontal = velocity == .zero ? translation : velocity
            return abs(horizontal.x) > abs(horizontal.y) * 2
        }
    }
}
