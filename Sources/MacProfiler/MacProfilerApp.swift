import AppKit
import SwiftUI

@MainActor
@Observable
final class ProfilerModel {
    private let sampler = Sampler()
    var snapshot: Snapshot

    init() {
        snapshot = sampler.sample()
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                snapshot = sampler.sample()
            }
        }
    }
}

@main
enum Entrypoint {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            let runner = DumpRunner()
            runner.run()
            return
        }
        MacProfilerApp.main()
    }
}

final class DumpRunner {
    func run() {
        let sampler = Sampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 1.1)
        let snapshot = sampler.sample()
        print(snapshot.debugText)
    }
}

struct MacProfilerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ProfilerModel()

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: 1120, height: 820)

        MenuBarExtra {
            MenuStatusView(model: model)
        } label: {
            Text(model.snapshot.menuLabel)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.install()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

enum DockIcon {
    static func install() {
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: 10, dy: 10), xRadius: 56, yRadius: 56)
            NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).setFill()
            background.fill()

            let center = NSPoint(x: rect.midX, y: rect.midY - 8)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: 72, startAngle: 206, endAngle: -26, clockwise: true)
            track.lineWidth = 18
            track.lineCapStyle = .round
            NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
            track.stroke()

            let value = NSBezierPath()
            value.appendArc(withCenter: center, radius: 72, startAngle: 206, endAngle: 48, clockwise: true)
            value.lineWidth = 18
            value.lineCapStyle = .round
            NSColor(calibratedRed: 0.49, green: 0.82, blue: 0.52, alpha: 1).setStroke()
            value.stroke()
            return true
        }
        image.isTemplate = false
        NSApplication.shared.applicationIconImage = image
    }
}
