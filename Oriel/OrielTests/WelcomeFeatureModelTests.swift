import Foundation
import Testing

@testable import Oriel

@MainActor
struct WelcomeFeatureModelTests {
  @Test
  func openingARecentFolderShowsItsBrowser() async {
    let folder = Folder(
      id: Folder.ID(),
      name: "Pictures",
      path: "/Pictures",
      url: URL(fileURLWithPath: "/Pictures")
    )
    let recent = RecentFolder(
      id: folder.id,
      name: folder.name,
      path: folder.path,
      availability: .available
    )
    let model = WelcomeFeatureModel(
      applicationInfo: TestApplicationInfoRepository(),
      folderAccess: TestFolderAccessRepository(folder: folder),
      recents: TestRecentsFolderRepository(folders: [recent])
    )

    await model.loadRecents()
    await model.openRecentFolder(recent)

    #expect(model.recentFolders == [recent])
    #expect(model.currentFolder == folder)
  }

  #if os(macOS)
    @Test
    func welcomeOpensOnlyAfterTheLastFolderWindowCloses() {
      let folder = Folder(
        id: Folder.ID(),
        name: "Pictures",
        path: "/Pictures",
        url: URL(fileURLWithPath: "/Pictures")
      )
      let coordinator = ApplicationWindowCoordinator(
        folderAccess: TestFolderAccessRepository(folder: folder),
        recents: TestRecentsFolderRepository(folders: [])
      )
      var welcomeOpenCount = 0
      coordinator.configure(
        openFolder: { _ in },
        openWelcome: { welcomeOpenCount += 1 },
        dismissWelcome: {}
      )
      let firstWindowID = UUID()
      let secondWindowID = UUID()

      coordinator.folderWindowDidAppear(id: firstWindowID, folderID: folder.id)
      coordinator.folderWindowDidAppear(id: secondWindowID, folderID: folder.id)
      coordinator.folderWindowDidDisappear(id: firstWindowID)
      #expect(welcomeOpenCount == 0)

      coordinator.folderWindowDidDisappear(id: secondWindowID)
      #expect(welcomeOpenCount == 1)
    }

    @Test
    func activeFolderFollowsTheKeyFolderWindow() {
      let firstFolderID = Folder.ID()
      let secondFolderID = Folder.ID()
      let coordinator = ApplicationWindowCoordinator(
        folderAccess: TestFolderAccessRepository(
          folder: Folder(
            id: firstFolderID,
            name: "Pictures",
            path: "/Pictures",
            url: URL(fileURLWithPath: "/Pictures")
          )
        ),
        recents: TestRecentsFolderRepository(folders: [])
      )
      let firstWindowID = UUID()
      let secondWindowID = UUID()

      coordinator.folderWindowDidAppear(id: firstWindowID, folderID: firstFolderID)
      coordinator.folderWindowDidAppear(id: secondWindowID, folderID: secondFolderID)
      #expect(coordinator.activeFolderID == secondFolderID)

      coordinator.folderWindowDidBecomeActive(id: firstWindowID)
      #expect(coordinator.activeFolderID == firstFolderID)
    }
  #endif
}

private struct TestApplicationInfoRepository: ApplicationInfoRepository {
  let version = "1.0"
}

private struct TestFolderAccessRepository: FolderAccessRepository {
  func authorizeTransient(_ url: URL) async throws -> Folder {
    Folder(id: Folder.ID(), name: url.lastPathComponent, path: url.path, url: url)
  }

  let folder: Folder

  func authorize(_ url: URL, replacing recentFolder: RecentFolder?) async throws -> Folder {
    folder
  }
  func openFolder(id: Folder.ID) async throws -> Folder { folder }
  func openFolder(matching url: URL) async throws -> Folder { folder }
  func recentFolder(id: Folder.ID) async throws -> RecentFolder {
    throw FolderAccessError.unavailable
  }
  func recentFolder(matching url: URL) async throws -> RecentFolder? { nil }
  func removeAuthorization(id: Folder.ID) async throws {}
  func stopAccessing(_ folder: Folder) async {}
}

private struct TestRecentsFolderRepository: RecentsFolderRepository {
  let folders: [RecentFolder]

  func recentFolders() async throws -> [RecentFolder] { folders }
  func record(_ folder: Folder, replacing recentFolder: RecentFolder?) async throws {}
  func clear() async throws {}
}
