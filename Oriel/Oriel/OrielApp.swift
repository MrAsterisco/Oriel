import FactoryKit
import SwiftUI

enum OrielWindowID {
  static let folder = "folder"
  static let welcome = "welcome"
}

@main
struct OrielApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(OrielApplicationDelegate.self) private var applicationDelegate
  #endif

  var body: some Scene {
    #if os(macOS)
      Window("Welcome to Oriel", id: OrielWindowID.welcome) {
        ContentView(
          model: Container.shared.welcomeFeatureModel(),
          windowCoordinator: Container.shared.applicationWindowCoordinator()
        )
      }
      .defaultLaunchBehavior(.presented)
      .defaultPosition(.center)
      .defaultSize(width: 840, height: 540)
      .windowResizability(.contentSize)
      .windowStyle(.hiddenTitleBar)

      WindowGroup("Oriel", id: OrielWindowID.folder, for: Folder.ID?.self) { folderID in
        if let folderID = folderID.wrappedValue {
          FolderWindowView(
            model: Container.shared.folderWindowFeatureModel(folderID),
            windowCoordinator: Container.shared.applicationWindowCoordinator()
          )
        }
      } defaultValue: {
        MainActor.assumeIsolated {
          Container.shared.applicationWindowCoordinator().activeFolderID
        }
      }
      .defaultLaunchBehavior(.suppressed)
    #else
      WindowGroup {
        ContentView(model: Container.shared.welcomeFeatureModel())
      }
    #endif
  }
}

#if os(macOS)
  import AppKit

  final class OrielApplicationDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
      Container.shared.applicationWindowCoordinator().openSystemRecentFolder(
        URL(fileURLWithPath: filename)
      )
      return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      false
    }
  }
#endif
