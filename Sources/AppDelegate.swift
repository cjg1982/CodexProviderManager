import AppKit
import Foundation

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(self)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
