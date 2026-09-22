import FactoryKit
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeFeatureView: View {
  #if os(macOS)
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
  #endif
  @State private var model: any WelcomeFeatureModelProtocol

  #if os(macOS)
    let windowCoordinator: any ApplicationWindowCoordinatorProtocol

    init(
      model: any WelcomeFeatureModelProtocol,
      windowCoordinator: any ApplicationWindowCoordinatorProtocol
    ) {
      _model = State(initialValue: model)
      self.windowCoordinator = windowCoordinator
    }
  #else
    init(model: any WelcomeFeatureModelProtocol) {
      _model = State(initialValue: model)
    }
  #endif

  var body: some View {
    Group {
      #if os(macOS)
        WelcomeView(model: model)
      #else
        if let folder = model.currentFolder {
          MediaBrowserView(folder: folder)
        } else {
          WelcomeView(model: model)
        }
      #endif
    }
    .fileImporter(
      isPresented: Binding(
        get: { model.isFolderPickerPresented },
        set: { model.setFolderPickerPresented($0) }
      ),
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      Task { await model.handleFolderSelection(result) }
    }
    .alert(
      "Couldn’t Open Folder",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.dismissError() } }
      )
    ) {
      Button("OK") { model.dismissError() }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .task { await model.loadRecents() }
    .onDisappear {
      Task { await model.stopAccessingCurrentFolder() }
    }
    #if os(macOS)
      .background(WelcomeWindowConfigurator())
      .onAppear { configureWindowActions() }
      .onChange(of: model.currentFolder) { _, folder in
        guard let folder else { return }
        windowCoordinator.openFolderWindow(id: folder.id)
      }
    #endif
  }

  #if os(macOS)
    private func configureWindowActions() {
      windowCoordinator.configure(
        openFolder: { openWindow(id: OrielWindowID.folder, value: Optional($0)) },
        openWelcome: { openWindow(id: OrielWindowID.welcome) },
        dismissWelcome: { dismissWindow(id: OrielWindowID.welcome) }
      )
    }
  #endif
}

#Preview {
  Container.shared.folderAccessRepository { PreviewFolderAccessRepository() }
  Container.shared.recentsFolderRepository { PreviewRecentsFolderRepository() }
  Container.shared.applicationInfoRepository { PreviewApplicationInfoRepository() }

  #if os(macOS)
    return WelcomeFeatureView(
      model: Container.shared.welcomeFeatureModel(),
      windowCoordinator: Container.shared.applicationWindowCoordinator()
    )
  #else
    return WelcomeFeatureView(model: Container.shared.welcomeFeatureModel())
  #endif
}

private struct PreviewFolderAccessRepository: FolderAccessRepository {
  func authorizeTransient(_ url: URL) async throws -> Folder {
    Folder(id: Folder.ID(), name: url.lastPathComponent, path: url.path, url: url)
  }

  func authorize(_ url: URL, replacing recentFolder: RecentFolder?) async throws -> Folder {
    Folder(
      id: recentFolder?.id ?? Folder.ID(), name: url.lastPathComponent, path: url.path, url: url)
  }

  func openFolder(id: Folder.ID) async throws -> Folder { throw FolderAccessError.unavailable }
  func openFolder(matching url: URL) async throws -> Folder { throw FolderAccessError.unavailable }
  func recentFolder(id: Folder.ID) async throws -> RecentFolder {
    throw FolderAccessError.unavailable
  }
  func recentFolder(matching url: URL) async throws -> RecentFolder? { nil }
  func removeAuthorization(id: Folder.ID) async throws {}
  func stopAccessing(_ folder: Folder) async {}
}

private struct PreviewRecentsFolderRepository: RecentsFolderRepository {
  func recentFolders() async throws -> [RecentFolder] {
    [
      RecentFolder(
        id: Folder.ID(),
        name: "Pictures",
        path: "/Users/example/Pictures",
        availability: .available
      ),
      RecentFolder(
        id: Folder.ID(),
        name: "Archive",
        path: "/Volumes/Archive",
        availability: .unavailable
      ),
    ]
  }

  func record(_ folder: Folder, replacing recentFolder: RecentFolder?) async throws {}
  func clear() async throws {}
}

private struct PreviewApplicationInfoRepository: ApplicationInfoRepository {
  let version = "1.0"
}
