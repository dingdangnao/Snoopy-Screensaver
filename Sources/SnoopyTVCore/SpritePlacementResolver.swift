import Foundation
import CoreGraphics

public enum SpritePlacementResolver {
    public static let designViewport = CGSize(width: 1920, height: 1080)

    public static func aspectFillFrame(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return bounds }
        let scale = max(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    public static func aspectFitFrame(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return bounds }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Resolve IdleCharacterUI's viewport-anchored sprite geometry. Apple
    /// authors these scenes in 1920x1080 coordinates. Every plane shares one
    /// aspect-fit design viewport: nothing is distorted or cropped, while the
    /// full-screen palette/halftone base naturally fills any remaining area.
    public static func frame(
        for sprite: SpriteRecord?, in bounds: CGRect,
        sceneOffset: PointRecord? = nil, ignoresSceneOffset: Bool = false
    ) -> CGRect {
        guard let size = sprite?.assetSize, size.count >= 2, size[0] > 0, size[1] > 0 else { return bounds }
        let boundsWidth = bounds.size.width
        let boundsHeight = bounds.size.height
        let designWidth = designViewport.width
        let designHeight = designViewport.height
        let scale = min(boundsWidth / designWidth, boundsHeight / designHeight)
        let viewportSize = CGSize(width: designWidth * scale, height: designHeight * scale)
        let viewport = CGRect(
            origin: CGPoint(
                x: bounds.origin.x + (boundsWidth - viewportSize.width) / 2,
                y: bounds.origin.y + (boundsHeight - viewportSize.height) / 2
            ),
            size: viewportSize
        )
        let spriteSize = CGSize(width: CGFloat(size[0]) * scale, height: CGFloat(size[1]) * scale)
        let alignment = sprite?.placement?.objectValue?["anchored"]?.objectValue?["alignment"]?.stringValue ?? "center"
        let viewportMidX = viewport.origin.x + viewport.size.width / 2
        let viewportMidY = viewport.origin.y + viewport.size.height / 2
        let originY: CGFloat
        switch alignment {
        case "bottom": originY = viewport.origin.y
        case "top": originY = viewport.origin.y + viewport.size.height - spriteSize.height
        default: originY = viewportMidY - spriteSize.height / 2
        }
        let offsetX = ignoresSceneOffset ? 0 : CGFloat(sceneOffset?.x ?? 0) * scale
        let offsetY = ignoresSceneOffset ? 0 : CGFloat(sceneOffset?.y ?? 0) * scale
        return CGRect(
            origin: CGPoint(x: viewportMidX - spriteSize.width / 2 + offsetX, y: originY + offsetY),
            size: spriteSize
        )
    }
}
