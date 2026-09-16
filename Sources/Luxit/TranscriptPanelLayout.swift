import CoreGraphics

enum TranscriptPanelLayout {
    static let size = CGSize(width: 560, height: 340)
    static func frame(in visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, max(0, visibleFrame.width - 32))
        let height = min(size.height, max(0, visibleFrame.height - 32))
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.maxY - height, width: width, height: height)
    }
}
