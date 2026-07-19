import SwiftUI
import AppKit

@main
struct PostedNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var board: BoardWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = BoardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Just above the desktop icons, below every normal window: the board
        // lives on the desktop instead of floating over other apps.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Window moves only via the header drag handle — background dragging
        // would hijack the note-card drag gestures.
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView: BoardView())
        if !window.setFrameUsingName("board") {
            window.center()
        }
        window.setFrameAutosaveName("board")
        window.makeKeyAndOrderFront(nil)
        board = window
    }
}

/// Borderless windows refuse key status by default, which would make the
/// note text fields uneditable; a desktop-level window also needs to
/// activate the (Dock-less) app on click before it can take keyboard focus.
final class BoardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            NSApp.activate(ignoringOtherApps: true)
        }
        super.sendEvent(event)
    }
}
