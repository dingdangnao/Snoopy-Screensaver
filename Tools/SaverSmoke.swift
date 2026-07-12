import AppKit
import Foundation

@main
enum SaverSmoke {
    static func main() {
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let width = environment["SNOOPY_SMOKE_WIDTH"].flatMap(Double.init) ?? 960
        let height = environment["SNOOPY_SMOKE_HEIGHT"].flatMap(Double.init) ?? 540
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let isPreview = environment["SNOOPY_SMOKE_PREVIEW"] == "1"
        guard let saver = SnoopySaverView(frame: frame, isPreview: isPreview) else {
            fatalError("Unable to initialize SnoopySaverView")
        }
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = saver
        let originX = environment["SNOOPY_SMOKE_ORIGIN_X"].flatMap(Double.init) ?? -2000
        let originY = environment["SNOOPY_SMOKE_ORIGIN_Y"].flatMap(Double.init) ?? 100
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        if originX >= 0 {
            window.level = .screenSaver
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        saver.startAnimation()

        if environment["SNOOPY_SMOKE_SCREENSHOTS"] != "0" {
            for index in 0..<12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 * Double(index + 1)) {
                    let rep = saver.bitmapImageRepForCachingDisplay(in: saver.bounds)!
                    saver.cacheDisplay(in: saver.bounds, to: rep)
                    let data = rep.representation(using: .png, properties: [:])!
                    try? data.write(to: URL(fileURLWithPath: "/tmp/snoopy-saver-smoke-\(index).png"))
                }
            }
        }
        let duration = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_DURATION"].flatMap(Double.init) ?? 10.5
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
        saver.stopAnimation()
    }
}
