import CoreGraphics
import Foundation
import Testing

@testable import Oriel

@MainActor
struct MediaBrowserFeatureModelTests {
  @Test
  func loadsMediaAndOpensAPicture() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let item = MediaItem(
      id: MediaItem.ID(url: rootURL.appending(path: "photo.jpg")),
      name: "photo.jpg",
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "photo.jpg"
    )
    let repository = TestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: mediaFolder,
        selectedFolder: nil,
        mediaItems: [item]
      )
    )
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    await model.run()
    await model.loadThumbnail(for: item)

    #expect(model.thumbnail(for: item) != nil)
    #expect(model.mediaItemsByID[item.id] == item)
    #expect(model.mediaItemsRevision == 1)
    #expect(model.mediaThumbnails[item.id] != nil)

    model.discardThumbnail(for: item)
    await model.activateMedia(item)

    #expect(model.mediaItems == [item])
    #expect(model.selectedDestination == .recents)
    #expect(model.selectedMediaID == item.id)
    #expect(model.thumbnail(for: item) == nil)
    #expect(model.openedMedia?.item == item)

    model.selectMedia(nil)
    let source = model.dragSource(for: item)
    #expect(source.id == item.id)
    #expect(model.selectedMediaID == nil)
  }

  @Test
  func cropsAPictureThroughTheViewerModeAndCanCancelOrSaveACopy() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let item = MediaItem(
      id: MediaItem.ID(url: rootURL.appending(path: "photo.jpg")),
      name: "photo.jpg",
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "photo.jpg"
    )
    let repository = TestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: MediaFolder(
          id: MediaFolder.ID(url: rootURL),
          name: "Pictures",
          path: rootURL.path,
          children: nil
        ),
        selectedFolder: nil,
        mediaItems: [item]
      ),
      picturePixelSize: MediaPixelSize(width: 1_200, height: 800)
    )
    let recorder = CropCallRecorder()
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(
        cropRecorder: recorder,
        cropResultURL: item.id.url
      ),
      folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .zero
    )

    await model.run()
    await model.activateMedia(item)
    await model.loadFileOperationCapabilities(for: .media(item))
    model.beginCrop()
    model.setCropRect(MediaNormalizedRect(x: 0.25, y: 0.125, width: 0.5, height: 0.5))

    guard case .crop(let crop) = model.viewerMode else {
      Issue.record("Expected crop mode")
      return
    }
    #expect(crop.pixelRect == MediaPixelRect(x: 300, y: 100, width: 600, height: 400))

    model.cancelViewerMode()
    #expect(model.viewerMode == nil)
    #expect(await recorder.calls().isEmpty)

    model.beginCrop()
    model.setCropRect(MediaNormalizedRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5))
    await model.saveCrop(asCopy: true)

    #expect(
      await recorder.calls() == [
        CropCall(
          item: item,
          rect: MediaPixelRect(x: 300, y: 200, width: 300, height: 400),
          saveAsCopy: true
        )
      ]
    )
    #expect(model.viewerMode == nil)
    #expect(!model.isSavingViewerMode)
    #expect(model.openedMedia?.item == item)
  }

  @Test
  func opensVideosDuringActivationAndNavigationAndLoops() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let firstPicture = MediaItem(
      id: MediaItem.ID(url: rootURL.appending(path: "1.jpg")),
      name: "1.jpg",
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "1.jpg"
    )
    let video = MediaItem(
      id: MediaItem.ID(url: rootURL.appending(path: "2.mov")),
      name: "2.mov",
      kind: .video,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "2.mov"
    )
    let lastPicture = MediaItem(
      id: MediaItem.ID(url: rootURL.appending(path: "3.jpg")),
      name: "3.jpg",
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "3.jpg"
    )
    let repository = TestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: mediaFolder,
        selectedFolder: nil,
        mediaItems: [firstPicture, video, lastPicture]
      )
    )
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    await model.run()
    await model.activateMedia(video)

    #expect(model.openedMedia?.item == video)

    await model.activateMedia(firstPicture)
    model.setViewerTransform(
      zoomScale: 1.05,
      panOffset: CGSize(width: 40, height: -20)
    )

    #expect(abs(model.zoomScale - 1.05) < 0.0001)
    #expect(model.panOffset == CGSize(width: 40, height: -20))

    await model.navigate(.next)

    #expect(model.openedMedia?.item == video)
    if case .video(let openedVideo) = model.openedMedia {
      #expect(openedVideo == video)
    } else {
      Issue.record("Expected the video to be open")
    }
    #expect(model.zoomScale == 1)
    #expect(model.panOffset == .zero)

    await model.navigate(.next)

    #expect(model.openedMedia?.item == lastPicture)

    await model.navigate(.next)

    #expect(model.openedMedia?.item == firstPicture)

    await model.navigate(.previous)

    #expect(model.openedMedia?.item == lastPicture)
  }

  @Test
  func switchesBetweenFolderAndRecentsDestinations() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let repository = TestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: mediaFolder,
        selectedFolder: nil,
        mediaItems: [
          MediaItem(
            id: MediaItem.ID(url: rootURL.appending(path: "photo.jpg")),
            name: "photo.jpg",
            kind: .picture,
            dateAdded: nil,
            fileSize: nil,
            modificationDate: nil,
            relativePath: "photo.jpg"
          )
        ]
      )
    )
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    await model.run()
    model.selectMedia(repository.snapshot.mediaItems[0])
    await model.selectDestination(.folder(mediaFolder.id))

    #expect(model.selectedDestination == .folder(mediaFolder.id))
    #expect(model.selectedDestinationName == "Pictures")
    #expect(model.selectedMediaID == nil)

    await model.selectDestination(.recents)

    #expect(model.selectedDestination == .recents)
    #expect(model.selectedDestinationName == "Recents")
  }

  @Test
  func filtersFoldersByNameCaseInsensitivelyAndPreservesTheirAncestors() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let familyURL = rootURL.appending(path: "Family", directoryHint: .isDirectory)
    let vacationURL = familyURL.appending(path: "Summer Vacation", directoryHint: .isDirectory)
    let workURL = rootURL.appending(path: "Work", directoryHint: .isDirectory)
    let folderTree = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: [
        MediaFolder(
          id: MediaFolder.ID(url: familyURL),
          name: "Family",
          path: familyURL.path,
          children: [
            MediaFolder(
              id: MediaFolder.ID(url: vacationURL),
              name: "Summer Vacation",
              path: vacationURL.path,
              children: nil
            )
          ]
        ),
        MediaFolder(
          id: MediaFolder.ID(url: workURL),
          name: "Work",
          path: workURL.path,
          children: nil
        ),
      ]
    )
    let model = MediaBrowserFeatureModel(
      folder: Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL),
      mediaRepository: TestMediaRepository(
        snapshot: MediaBrowserSnapshot(
          folderTree: folderTree,
          selectedFolder: nil,
          mediaItems: []
        )
      ),
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    await model.run()
    model.setFolderSearchText("vAcAtIoN")

    #expect(model.filteredFolderTree?.children?.map(\.name) == ["Family"])
    #expect(model.filteredFolderTree?.children?.first?.children?.map(\.name) == ["Summer Vacation"])

    model.setFolderSearchText("work")

    #expect(model.filteredFolderTree?.children?.map(\.name) == ["Work"])

    model.setFolderSearchText("missing")

    #expect(model.filteredFolderTree == nil)

    model.setFolderSearchText("   ")

    #expect(model.filteredFolderTree == folderTree)
  }

  @Test
  func revealsRecentMediaInItsContainingFolder() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let containingFolderURL = rootURL.appending(path: "Trips", directoryHint: .isDirectory)
    let item = MediaItem(
      id: MediaItem.ID(url: containingFolderURL.appending(path: "photo.jpg")),
      name: "photo.jpg",
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "Trips/photo.jpg"
    )
    let folderTree = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: [
        MediaFolder(
          id: MediaFolder.ID(url: containingFolderURL),
          name: "Trips",
          path: containingFolderURL.path,
          children: nil
        )
      ]
    )
    let model = MediaBrowserFeatureModel(
      folder: Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL),
      mediaRepository: TestMediaRepository(
        snapshot: MediaBrowserSnapshot(
          folderTree: folderTree,
          selectedFolder: nil,
          mediaItems: [item]
        )
      ),
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    await model.run()
    await model.activateMedia(item)
    await model.revealInFolder(item)

    #expect(model.selectedDestination == .folder(MediaFolder.ID(url: containingFolderURL)))
    #expect(model.selectedFolder?.id == MediaFolder.ID(url: containingFolderURL))
    #expect(model.selectedMediaID == item.id)
    #expect(model.openedMedia?.item == nil)
  }

  @Test
  func selectsOneSortOptionAndTogglesItsDirection() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let repository = TestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: mediaFolder,
        selectedFolder: mediaFolder,
        mediaItems: []
      )
    )
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    #expect(model.mediaSort == .initial)

    await model.selectSortOption(.name)
    #expect(model.mediaSort == MediaSort(option: .name, direction: .ascending))

    await model.selectSortOption(.name)
    #expect(model.mediaSort == MediaSort(option: .name, direction: .descending))

    await model.selectSortOption(.size)
    #expect(model.mediaSort == MediaSort(option: .size, direction: .ascending))
  }

  @Test
  func preservesSelectionAcrossRefreshAndClearsItWhenTheItemDisappears() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let item = MediaItem(
      id: MediaItem.ID(url: rootURL.appending(path: "photo.jpg")),
      name: "photo.jpg",
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "photo.jpg"
    )
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: mediaFolder,
        selectedFolder: nil,
        mediaItems: [item]
      )
    )
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    await model.run()
    model.selectMedia(item)
    await model.retry()
    #expect(model.selectedMediaID == item.id)

    await repository.setMediaItems([])
    await model.retry()
    #expect(model.selectedMediaID == nil)
  }

  @Test
  func coalescesMutationAndFileChangeRefreshes() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let item = MediaItem(
      id: MediaItem.ID(url: rootURL.appending(path: "photo.jpg")),
      name: "photo.jpg",
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: "photo.jpg"
    )
    let repository = RefreshingTestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: mediaFolder,
        selectedFolder: nil,
        mediaItems: [item]
      )
    )
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .milliseconds(20)
    )

    let runTask = Task { await model.run() }
    while await repository.snapshotCount() == 0 { await Task.yield() }
    while model.isLoading { await Task.yield() }

    let transferTask = Task {
      await model.transfer(
        [MediaTransferSource(item: item)],
        to: MediaTransferDestination(folderID: mediaFolder.id),
        operation: .copy
      )
    }
    while !(await repository.didTransfer()) { await Task.yield() }
    await Task.yield()

    #expect(!model.isLoading)
    await transferTask.value
    #expect(await repository.snapshotCount() == 2)
    await repository.finishUpdates()
    await runTask.value
  }

  @Test
  func destinationChangeCancelsAStaleRefresh() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let repository = DelayedTestMediaRepository(folder: mediaFolder)
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )

    let runTask = Task { await model.run() }
    while await repository.snapshotCount() == 0 { await Task.yield() }
    await model.selectDestination(.folder(mediaFolder.id))

    #expect(model.selectedDestination == .folder(mediaFolder.id))
    #expect(model.selectedFolder == mediaFolder)
    await repository.finishUpdates()
    await runTask.value
  }

  @Test
  func fileChangesDoNotCancelAnActiveRefresh() async {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let mediaFolder = MediaFolder(
      id: MediaFolder.ID(url: rootURL),
      name: "Pictures",
      path: rootURL.path,
      children: nil
    )
    let repository = RefreshingTestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: mediaFolder,
        selectedFolder: nil,
        mediaItems: []
      ),
      snapshotDelay: .milliseconds(40)
    )
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .milliseconds(5)
    )

    let runTask = Task { await model.run() }
    while model.isLoading { await Task.yield() }
    await repository.sendFileChanges(1)
    while await repository.snapshotCount() < 2 { await Task.yield() }
    await repository.sendFileChanges(20)
    try? await Task.sleep(for: .milliseconds(120))

    #expect(await repository.snapshotCount() == 3)
    #expect(await repository.cancelledSnapshotCount() == 0)
    #expect(await repository.completedSnapshotCount() == 3)
    await repository.finishUpdates()
    await runTask.value
  }

  #if os(macOS)
    @Test
    func loadsApplicationsThatCanOpenAMediaItem() async {
      let rootURL = URL(fileURLWithPath: "/Pictures")
      let item = MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: "photo.jpg")),
        name: "photo.jpg",
        kind: .picture,
        dateAdded: nil,
        fileSize: nil,
        modificationDate: nil,
        relativePath: "photo.jpg"
      )
      let application = FileOpeningApplication(
        id: URL(fileURLWithPath: "/Applications/Preview.app"),
        name: "Preview"
      )
      let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
      let model = MediaBrowserFeatureModel(
        folder: folder,
        mediaRepository: TestMediaRepository(
          snapshot: MediaBrowserSnapshot(
            folderTree: MediaFolder(
              id: MediaFolder.ID(url: rootURL),
              name: "Pictures",
              path: rootURL.path,
              children: nil
            ),
            selectedFolder: nil,
            mediaItems: [item]
          )
        ),
        fileOperations: TestFileOperationRepository(openingApplications: [application]),
        folderAccess: TestMediaFolderAccessRepository()
      )

      await model.loadOpeningApplications(for: .media(item))

      #expect(model.openingApplications[item.id.url.standardizedFileURL] == [application])
    }
  #endif
}

private struct TestMediaRepository: MediaRepository {
  let snapshot: MediaBrowserSnapshot
  var picturePixelSize: MediaPixelSize? = nil

  func snapshot(
    of rootFolder: Folder,
    destination: MediaBrowserDestination,
    sort: MediaSort
  ) async throws -> MediaBrowserSnapshot {
    guard case .folder(let id) = destination else {
      return snapshot
    }
    let selectedFolder = MediaFolder(
      id: id,
      name: id.url.lastPathComponent,
      path: id.url.path,
      children: nil
    )
    return MediaBrowserSnapshot(
      folderTree: snapshot.folderTree,
      selectedFolder: selectedFolder,
      mediaItems: snapshot.mediaItems
    )
  }

  func recentMedia(in rootFolder: Folder) async throws -> [MediaItem] {
    snapshot.mediaItems
  }

  func thumbnail(for item: MediaItem) async throws -> MediaThumbnail {
    MediaThumbnail(image: testMediaImage())
  }

  func picture(for item: MediaItem) async throws -> PictureContent {
    PictureContent(item: item, image: testMediaImage(), pixelSize: picturePixelSize)
  }

  func transfer(_ transfer: MediaTransfer, in rootFolder: Folder) async throws {}

  func updates(in folder: Folder) async -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
}

private actor MutableTestMediaRepository: MediaRepository {
  private var currentSnapshot: MediaBrowserSnapshot

  init(snapshot: MediaBrowserSnapshot) {
    currentSnapshot = snapshot
  }

  func setMediaItems(_ mediaItems: [MediaItem]) {
    currentSnapshot = MediaBrowserSnapshot(
      folderTree: currentSnapshot.folderTree,
      selectedFolder: currentSnapshot.selectedFolder,
      mediaItems: mediaItems
    )
  }

  func snapshot(
    of rootFolder: Folder,
    destination: MediaBrowserDestination,
    sort: MediaSort
  ) async throws -> MediaBrowserSnapshot {
    currentSnapshot
  }

  func recentMedia(in rootFolder: Folder) async throws -> [MediaItem] {
    currentSnapshot.mediaItems
  }

  func thumbnail(for item: MediaItem) async throws -> MediaThumbnail {
    MediaThumbnail(image: testMediaImage())
  }

  func picture(for item: MediaItem) async throws -> PictureContent {
    PictureContent(item: item, image: testMediaImage())
  }

  func transfer(_ transfer: MediaTransfer, in rootFolder: Folder) async throws {}

  func updates(in folder: Folder) async -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
}

private actor RefreshingTestMediaRepository: MediaRepository {
  private let changeContinuation: AsyncStream<Void>.Continuation
  private let changeStream: AsyncStream<Void>
  private let currentSnapshot: MediaBrowserSnapshot
  private let snapshotDelay: Duration?
  private var currentCancelledSnapshotCount = 0
  private var currentCompletedSnapshotCount = 0
  private var didPerformTransfer = false
  private var currentSnapshotCount = 0

  init(snapshot: MediaBrowserSnapshot, snapshotDelay: Duration? = nil) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    changeStream = stream
    changeContinuation = continuation
    currentSnapshot = snapshot
    self.snapshotDelay = snapshotDelay
  }

  func snapshot(
    of rootFolder: Folder,
    destination: MediaBrowserDestination,
    sort: MediaSort
  ) async throws -> MediaBrowserSnapshot {
    currentSnapshotCount += 1
    if currentSnapshotCount > 1, let snapshotDelay {
      do {
        try await Task.sleep(for: snapshotDelay)
      } catch {
        currentCancelledSnapshotCount += 1
        throw error
      }
    }
    currentCompletedSnapshotCount += 1
    return currentSnapshot
  }

  func recentMedia(in rootFolder: Folder) async throws -> [MediaItem] {
    currentSnapshot.mediaItems
  }

  func thumbnail(for item: MediaItem) async throws -> MediaThumbnail {
    MediaThumbnail(image: testMediaImage())
  }

  func picture(for item: MediaItem) async throws -> PictureContent {
    PictureContent(item: item, image: testMediaImage())
  }

  func transfer(_ transfer: MediaTransfer, in rootFolder: Folder) async throws {
    changeContinuation.yield()
    changeContinuation.yield()
    changeContinuation.yield()
    didPerformTransfer = true
  }

  func updates(in folder: Folder) async -> AsyncStream<Void> {
    changeStream
  }

  func snapshotCount() -> Int {
    currentSnapshotCount
  }

  func didTransfer() -> Bool {
    didPerformTransfer
  }

  func sendFileChanges(_ count: Int) {
    for _ in 0..<count { changeContinuation.yield() }
  }

  func cancelledSnapshotCount() -> Int {
    currentCancelledSnapshotCount
  }

  func completedSnapshotCount() -> Int {
    currentCompletedSnapshotCount
  }

  func finishUpdates() {
    changeContinuation.finish()
  }
}

private actor DelayedTestMediaRepository: MediaRepository {
  private let changeContinuation: AsyncStream<Void>.Continuation
  private let changeStream: AsyncStream<Void>
  private let folder: MediaFolder
  private var currentSnapshotCount = 0

  init(folder: MediaFolder) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    changeStream = stream
    changeContinuation = continuation
    self.folder = folder
  }

  func snapshot(
    of rootFolder: Folder,
    destination: MediaBrowserDestination,
    sort: MediaSort
  ) async throws -> MediaBrowserSnapshot {
    currentSnapshotCount += 1
    switch destination {
    case .recents:
      try await Task.sleep(for: .seconds(1))
      return MediaBrowserSnapshot(folderTree: folder, selectedFolder: nil, mediaItems: [])
    case .folder:
      return MediaBrowserSnapshot(folderTree: folder, selectedFolder: folder, mediaItems: [])
    }
  }

  func recentMedia(in rootFolder: Folder) async throws -> [MediaItem] { [] }

  func thumbnail(for item: MediaItem) async throws -> MediaThumbnail {
    MediaThumbnail(image: testMediaImage())
  }

  func picture(for item: MediaItem) async throws -> PictureContent {
    PictureContent(item: item, image: testMediaImage())
  }

  func transfer(_ transfer: MediaTransfer, in rootFolder: Folder) async throws {}

  func updates(in folder: Folder) async -> AsyncStream<Void> {
    changeStream
  }

  func snapshotCount() -> Int {
    currentSnapshotCount
  }

  func finishUpdates() {
    changeContinuation.finish()
  }
}

private struct TestFileOperationRepository: FileOperationRepository {
  var cropRecorder: CropCallRecorder?
  var cropResultURL: URL?

  #if os(macOS)
    var openingApplications: [FileOpeningApplication] = []
  #endif

  func capabilities(
    for target: FileOperationTarget,
    in rootFolder: Folder
  ) async -> FileOperationCapabilities {
    FileOperationCapabilities(canModify: true, canModifyContents: true, canMoveToTrash: true)
  }

  func rename(
    _ target: FileOperationTarget,
    to name: String,
    in rootFolder: Folder
  ) async throws -> URL {
    target.url
  }

  func duplicate(_ target: FileOperationTarget, in rootFolder: Folder) async throws -> URL {
    target.url
  }

  func copy(_ target: FileOperationTarget, in rootFolder: Folder) async throws {}
  func paste(into folder: MediaFolder, in rootFolder: Folder) async throws {}

  func move(
    _ target: FileOperationTarget,
    to destinationURL: URL,
    in rootFolder: Folder
  ) async throws -> URL {
    destinationURL.appending(path: target.url.lastPathComponent)
  }

  func createFolder(
    named name: String,
    in folder: MediaFolder,
    rootFolder: Folder
  ) async throws {}

  func cropPicture(
    _ item: MediaItem,
    to rect: MediaPixelRect,
    saveAsCopy: Bool,
    in rootFolder: Folder
  ) async throws -> URL {
    await cropRecorder?.record(CropCall(item: item, rect: rect, saveAsCopy: saveAsCopy))
    return cropResultURL ?? item.id.url
  }

  func moveToTrash(_ target: FileOperationTarget, in rootFolder: Folder) async throws {}
  func delete(_ target: FileOperationTarget, in rootFolder: Folder) async throws {}

  func info(for target: FileOperationTarget, in rootFolder: Folder) async throws -> FileItemInfo {
    FileItemInfo(
      id: target.url,
      name: target.name,
      kind: "File",
      fileSize: nil,
      dateAdded: nil,
      creationDate: nil,
      modificationDate: nil,
      pixelWidth: nil,
      pixelHeight: nil,
      duration: nil,
      location: target.url.deletingLastPathComponent().path
    )
  }

  func reveal(_ target: FileOperationTarget, in rootFolder: Folder) async throws {}

  #if os(macOS)
    func openingApplications(
      for target: FileOperationTarget,
      in rootFolder: Folder
    ) async throws -> [FileOpeningApplication] {
      openingApplications
    }

    func open(
      _ target: FileOperationTarget,
      with applicationURL: URL,
      in rootFolder: Folder
    ) async throws {}
  #endif
}

private struct CropCall: Equatable, Sendable {
  let item: MediaItem
  let rect: MediaPixelRect
  let saveAsCopy: Bool
}

private actor CropCallRecorder {
  private var recordedCalls: [CropCall] = []

  func record(_ call: CropCall) {
    recordedCalls.append(call)
  }

  func calls() -> [CropCall] {
    recordedCalls
  }
}

private struct TestMediaFolderAccessRepository: FolderAccessRepository {
  func authorize(_ url: URL, replacing recentFolder: RecentFolder?) async throws -> Folder {
    Folder(id: Folder.ID(), name: url.lastPathComponent, path: url.path, url: url)
  }

  func authorizeTransient(_ url: URL) async throws -> Folder {
    Folder(id: Folder.ID(), name: url.lastPathComponent, path: url.path, url: url)
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

nonisolated private func testMediaImage() -> MediaImage {
  let context = CGContext(
    data: nil,
    width: 1,
    height: 1,
    bitsPerComponent: 8,
    bytesPerRow: 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )
  return MediaImage(cgImage: context!.makeImage()!)
}
