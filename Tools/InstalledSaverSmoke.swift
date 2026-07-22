import AppKit
import Foundation
import ScreenSaver

@main
enum InstalledSaverSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "InstalledSaverSmoke", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "usage: InstalledSaverSmoke '/path/SNOOPY.saver'"])
        }
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let width = environment["SNOOPY_SMOKE_WIDTH"].flatMap(Double.init) ?? 960
        let height = environment["SNOOPY_SMOKE_HEIGHT"].flatMap(Double.init) ?? 600
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            throw NSError(domain: "InstalledSaverSmoke", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "invalid saver bundle"])
        }
        try bundle.loadAndReturnError()
        guard let saverType = bundle.principalClass as? ScreenSaverView.Type,
              let saver = saverType.init(
                frame: NSRect(x: 0, y: 0, width: width, height: height), isPreview: false
              ) else {
            throw NSError(domain: "InstalledSaverSmoke", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "unable to instantiate principal ScreenSaverView"])
        }
        let window = NSWindow(contentRect: saver.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let originX = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_ORIGIN_X"].flatMap(Double.init) ?? -2000
        let originY = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_ORIGIN_Y"].flatMap(Double.init) ?? 100
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        window.contentView = saver
        if originX >= 0 {
            if ProcessInfo.processInfo.environment["SNOOPY_SMOKE_NORMAL_LEVEL"] != "1" {
                window.level = .screenSaver
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        if let path = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_WINDOW_ID_PATH"] {
            try String(window.windowNumber).write(
                to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8
            )
        }
        saver.startAnimation()
        let duration = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_DURATION"].flatMap(Double.init) ?? 30
        if let screenshotDirectory = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: screenshotDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let interval = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_SCREENSHOT_INTERVAL"]
                .flatMap(Double.init) ?? 0.25
            let count = max(1, Int(duration / interval))
            for index in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index + 1)) {
                    guard let representation = saver.bitmapImageRepForCachingDisplay(in: saver.bounds) else { return }
                    saver.cacheDisplay(in: saver.bounds, to: representation)
                    guard let data = representation.representation(using: .png, properties: [:]) else { return }
                    try? data.write(to: directory.appendingPathComponent(String(format: "%04d.png", index)))
                }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
        saver.stopAnimation()
        let postStopDuration = ProcessInfo.processInfo.environment["SNOOPY_SMOKE_POST_STOP_DURATION"]
            .flatMap(Double.init) ?? 0
        if postStopDuration > 0 {
            print("Snoopy smoke: stopped; keeping host alive for \(postStopDuration) seconds")
            fflush(stdout)
            RunLoop.main.run(until: Date().addingTimeInterval(postStopDuration))
        }
    }
}
