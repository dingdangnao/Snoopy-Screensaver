import AppKit
import Foundation
import ScreenSaver

@main
enum ConfigurationSmoke {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            throw NSError(
                domain: "ConfigurationSmoke", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "usage: ConfigurationSmoke '/path/SNOOPY.saver' [screenshot.png]"]
            )
        }
        let application = NSApplication.shared
        switch ProcessInfo.processInfo.environment["SNOOPY_SMOKE_APPEARANCE"] {
        case "dark": application.appearance = NSAppearance(named: .darkAqua)
        case "light": application.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            throw NSError(domain: "ConfigurationSmoke", code: 3)
        }
        try bundle.loadAndReturnError()
        guard let saverType = bundle.principalClass as? ScreenSaverView.Type,
              let saver = saverType.init(
                frame: NSRect(x: 0, y: 0, width: 960, height: 540), isPreview: true
              ),
              saver.hasConfigureSheet,
              let panel = saver.configureSheet,
              let content = panel.contentView else {
            throw NSError(
                domain: "ConfigurationSmoke", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "configuration sheet unavailable"]
            )
        }
        panel.setFrameOrigin(NSPoint(x: 100, y: 100))
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if CommandLine.arguments.count >= 3,
           let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: representation)
            let data = representation.representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        let appearance = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
        print("configuration smoke OK: \(panel.title) \(Int(content.bounds.width))x\(Int(content.bounds.height)) appearance=\(appearance)")
        panel.orderOut(nil)
    }
}
