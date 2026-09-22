#if os(macOS)
  import Foundation

  @MainActor
  protocol ApplicationWindowCoordinatorProtocol: AnyObject {
    var activeFolderID: Folder.ID? { get }

    func configure(
      openFolder: @escaping @MainActor (Folder.ID) -> Void,
      openWelcome: @escaping @MainActor () -> Void,
      dismissWelcome: @escaping @MainActor () -> Void
    )
    func folderWindowDidAppear(id: UUID, folderID: Folder.ID)
    func folderWindowDidBecomeActive(id: UUID)
    func folderWindowDidDisappear(id: UUID)
    func openFolderWindow(id: Folder.ID)
    func openSystemRecentFolder(_ url: URL)
  }

  @MainActor
  final class ApplicationWindowCoordinator: ApplicationWindowCoordinatorProtocol {
    private let folderAccess: any FolderAccessRepository
    private let recents: any RecentsFolderRepository
    private var folderWindowFolderIDs: [UUID: Folder.ID] = [:]
    private var activeFolderWindowID: UUID?
    private var openFolder: ((Folder.ID) -> Void)?
    private var openWelcome: (() -> Void)?
    private var dismissWelcome: (() -> Void)?
    private var pendingFolderID: Folder.ID?
    private var shouldOpenWelcome = false

    init(
      folderAccess: any FolderAccessRepository,
      recents: any RecentsFolderRepository
    ) {
      self.folderAccess = folderAccess
      self.recents = recents
    }

    func configure(
      openFolder: @escaping @MainActor (Folder.ID) -> Void,
      openWelcome: @escaping @MainActor () -> Void,
      dismissWelcome: @escaping @MainActor () -> Void
    ) {
      self.openFolder = openFolder
      self.openWelcome = openWelcome
      self.dismissWelcome = dismissWelcome

      if let pendingFolderID {
        self.pendingFolderID = nil
        openFolderWindow(id: pendingFolderID)
      } else if shouldOpenWelcome {
        shouldOpenWelcome = false
        openWelcome()
      }
    }

    var activeFolderID: Folder.ID? {
      activeFolderWindowID.flatMap { folderWindowFolderIDs[$0] }
    }

    func folderWindowDidAppear(id: UUID, folderID: Folder.ID) {
      folderWindowFolderIDs[id] = folderID
      activeFolderWindowID = id
    }

    func folderWindowDidBecomeActive(id: UUID) {
      guard folderWindowFolderIDs[id] != nil else { return }
      activeFolderWindowID = id
    }

    func folderWindowDidDisappear(id: UUID) {
      guard folderWindowFolderIDs.removeValue(forKey: id) != nil else { return }
      if activeFolderWindowID == id {
        activeFolderWindowID = nil
      }
      guard folderWindowFolderIDs.isEmpty else { return }
      showWelcome()
    }

    func openFolderWindow(id: Folder.ID) {
      guard let openFolder else {
        pendingFolderID = id
        return
      }
      openFolder(id)
      dismissWelcome?()
    }

    func openSystemRecentFolder(_ url: URL) {
      Task {
        do {
          let folder = try await folderAccess.openFolder(matching: url)
          try? await recents.record(folder, replacing: nil)
          openFolderWindow(id: folder.id)
          await folderAccess.stopAccessing(folder)
        } catch {
          showWelcome()
        }
      }
    }

    private func showWelcome() {
      guard let openWelcome else {
        shouldOpenWelcome = true
        return
      }
      openWelcome()
    }
  }
#endif
