import CoreGraphics

enum VoiceOrbLayout {
    static let size = CGSize(width: 280, height: 280)
    static let inset: CGFloat = 18

    static func frame(in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - size.width - inset,
            y: visibleFrame.minY + inset,
            width: size.width,
            height: size.height
        )
    }
}
