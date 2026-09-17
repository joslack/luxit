import CoreGraphics

enum VoiceOrbLayout {
    static let size = CGSize(width: 320, height: 320)
    static let inset: CGFloat = 18

    static func pixelsPerPoint(drawableWidth: CGFloat, logicalWidth: CGFloat) -> CGFloat {
        guard drawableWidth.isFinite, logicalWidth.isFinite,
              drawableWidth > 0, logicalWidth > 0 else { return 1 }
        return drawableWidth / logicalWidth
    }

    static func frame(in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - size.width - inset,
            y: visibleFrame.minY + inset,
            width: size.width,
            height: size.height
        )
    }
}
