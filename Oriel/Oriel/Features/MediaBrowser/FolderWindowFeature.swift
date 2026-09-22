#if os(macOS)
  import Observation
  import SwiftUI

  @MainActor
  protocol FolderWindowFeatureModelProtocol: AnyObject, Observable {
    var errorMessage: String? { get }
    var folder: Folder? { get }
    var folderID: Folder.ID { get }

    func load() async
    func stopAccessingFolder() async
  }

  @MainActor
  @Observable
  final class FolderWindowFeatureModel: FolderWindowFeatureModelProtocol {
    private let folderAccess: any FolderAccessRepository
    let folderID: Folder.ID
    private var hasLoaded = false

    private(set) var errorMessage: String?
    private(set) var folder: Folder?

    init(folderID: Folder.ID, folderAccess: any FolderAccessRepository) {
      self.folderID = folderID
      self.folderAccess = folderAccess
    }

    func load() async {
      guard !hasLoaded else { return }
      hasLoaded = true

      do {
        folder = try await folderAccess.openFolder(id: folderID)
      } catch {
        errorMessage = error.localizedDescription
      }
    }

    func stopAccessingFolder() async {
      guard let folder else { return }
      await folderAccess.stopAccessing(folder)
      self.folder = nil
    }
  }

  struct FolderWindowView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var model: any FolderWindowFeatureModelProtocol
    @State private var windowID = UUID()

    let windowCoordinator: any ApplicationWindowCoordinatorProtocol

    init(
      model: any FolderWindowFeatureModelProtocol,
      windowCoordinator: any ApplicationWindowCoordinatorProtocol
    ) {
      _model = State(initialValue: model)
      self.windowCoordinator = windowCoordinator
    }

    var body: some View {
      Group {
        if let folder = model.folder {
          MediaBrowserView(folder: folder)
        } else if let errorMessage = model.errorMessage {
          ContentUnavailableView(
            "Couldn’t Open Folder",
            systemImage: "folder.badge.questionmark",
            description: Text(errorMessage)
          )
        } else {
          ProgressView("Opening Folder…")
        }
      }
      .frame(minWidth: 640, minHeight: 440)
      .onAppear {
        configureWindowActions()
        windowCoordinator.folderWindowDidAppear(id: windowID, folderID: model.folderID)
      }
      .onChange(of: controlActiveState) { _, state in
        guard state == .key else { return }
        windowCoordinator.folderWindowDidBecomeActive(id: windowID)
      }
      .task { await model.load() }
      .onDisappear {
        windowCoordinator.folderWindowDidDisappear(id: windowID)
        Task { await model.stopAccessingFolder() }
      }
    }

    private func configureWindowActions() {
      windowCoordinator.configure(
        openFolder: { openWindow(id: OrielWindowID.folder, value: Optional($0)) },
        openWelcome: { openWindow(id: OrielWindowID.welcome) },
        dismissWelcome: { dismissWindow(id: OrielWindowID.welcome) }
      )
    }
  }
#endif
