import Foundation
import Testing

@testable import Oriel

struct FolderAccessRepositoryTests {
  @Test
  func accessRemainsActiveUntilItsLastOwnerReleasesIt() {
    var access = ActiveFolderAccess(
      url: URL(fileURLWithPath: "/Pictures"),
      shouldStop: true
    )

    access.retain()
    let firstReleaseEndedAccess = access.release()

    #expect(!firstReleaseEndedAccess)
    #expect(access.retainCount == 1)
    let finalReleaseEndedAccess = access.release()
    #expect(finalReleaseEndedAccess)
    #expect(access.retainCount == 0)
  }

  @Test
  func transientAccessDoesNotPersistARecentFolderAuthorization() async throws {
    let suiteName = "FolderAccessRepositoryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let url = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }

    let repository = BookmarkFolderAccessRepository(defaults: defaults)
    let folder = try await repository.authorizeTransient(url)

    #expect(folder.url == url)
    await #expect(throws: FolderAccessError.self) {
      try await repository.recentFolder(id: folder.id)
    }
    await repository.stopAccessing(folder)
  }
}
