#if os(macOS)
  import AppKit
  import SwiftUI

  struct WelcomeWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
      NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
      DispatchQueue.main.async {
        guard let window = view.window else { return }
        window.isExcludedFromWindowsMenu = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.styleMask.remove([.miniaturizable, .resizable])
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
      }
    }
  }
#endif
