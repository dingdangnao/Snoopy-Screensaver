import Foundation
import CoreGraphics

public enum SpritePlacementResolver {
    public static let designViewport = CGSize(width: 1920, height: 1080)

    /// The authored 16:9 canvas used by frame sequences and metadata-driven
    /// composites. It is never cropped or distorted: 16:9 fills the display,
    /// taller displays retain the full width, and ultrawide displays retain
    /// the full height while centering the canvas.
    public static func playbackViewport(in bounds: CGRect) -> CGRect {
        aspectFitFrame(contentSize: designViewport, in: bounds)
    }

    /// Standalone ActiveScene movies always fill the display height. Narrower
    /// displays (16:10, 4:3, and 1:1) crop equal amounts from the left and
    /// right; ultrawide displays keep the full movie and expose black sidebars.
    public static func activeVideoViewport(in bounds: CGRect) -> CGRect {
        guard bounds.height > 0 else { return bounds }
        let scale = bounds.height / designViewport.height
        let size = CGSize(width: designViewport.width * scale, height: bounds.height)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.minY,
            width: size.width, height: size.height
        )
    }

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
        guard let size = sprite?.assetSize, size.count >= 2, size[0] > 0, size[1] > 0 else {
            return playbackViewport(in: bounds)
        }
        let designWidth = designViewport.width
        let viewport = playbackViewport(in: bounds)
        let scale = viewport.width / designWidth
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
        // IdleCharacter metadata is authored in UIKit/tvOS coordinates, where
        // negative Y moves a scene upward. AppKit's layer geometry uses an
        // upward-positive Y axis, so the vertical component must be inverted.
        let offsetY = ignoresSceneOffset ? 0 : -CGFloat(sceneOffset?.y ?? 0) * scale
        return CGRect(
            origin: CGPoint(x: viewportMidX - spriteSize.width / 2 + offsetX, y: originY + offsetY),
            size: spriteSize
        )
    }
}
