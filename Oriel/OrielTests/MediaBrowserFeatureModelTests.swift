import CoreGraphics
import Foundation
import Testing

@testable import Oriel

@MainActor
struct MediaBrowserFeatureModelTests {
  @Test
  func faceThumbnailsLoadOnDemandAndReleaseWhenDiscarded() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let root = Folder(id: .init(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: root.name, path: root.path, children: nil)
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: []))
    let model = MediaBrowserFeatureModel(
      folder: root, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    let source = testFaceThumbnailSource()
    #expect(model.faceThumbnails.isEmpty)
    await model.loadFaceThumbnail(source)
    weak var image = model.faceThumbnails[source.id]?.image.cgImage
    #expect(image != nil)
    model.discardFaceThumbnail(source)
    #expect(model.faceThumbnails.isEmpty)
    #expect(image == nil)
    await model.loadFaceThumbnail(source)
    #expect(model.faceThumbnails[source.id] != nil)
    await model.selectDestination(.people)
    #expect(model.faceThumbnails.isEmpty)
  }

  @Test
  func sidebarMultipleSelectionClearsMediaAndKeepsAggregateDestinationsExclusive() async throws {
    let url = URL(fileURLWithPath: "/Pictures", isDirectory: true)
    let root = Folder(id: .init(), name: "Pictures", path: url.path, url: url)
    let children = ["Alpha", "Zulu"].map { name in
      let child = url.appending(path: name, directoryHint: .isDirectory)
      return MediaFolder(id: .init(url: child), name: name, path: child.path, children: nil)
    }
    let tree = MediaFolder(
      id: .init(url: url), name: root.name, path: root.path, children: children)
    let items = children.map { folder in
      MediaItem(
        id: .init(url: folder.id.url.appending(path: "photo.jpg")), name: "photo.jpg",
        kind: .picture, dateAdded: nil, fileSize: nil, modificationDate: nil,
        relativePath: "\(folder.name)/photo.jpg")
    }
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: items))
    let model = MediaBrowserFeatureModel(
      folder: root, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    await model.run()
    await model.selectDestination(.folder(children[0].id))
    model.selectMedia(items[0])
    let selection = Set(children.map { MediaBrowserDestination.folder($0.id) })
    await model.selectSidebarDestinations(selection)
    #expect(model.sidebarSelection == selection)
    #expect(model.selectedFolder == nil)
    #expect(model.selectedMediaID == nil)
    #expect(model.mediaSections.map(\.title) == ["Alpha", "Zulu"])
    #expect(model.mediaItems == items)
    for child in children { await model.loadFileOperationCapabilities(for: .folder(child)) }
    #expect(model.canMergeSelectedFolders)
    await model.activateMedia(items[0])
    await model.navigate(.next)
    #expect(model.openedMedia?.item.id == items[1].id)
    await model.selectSidebarDestinations(selection.union([.recents]))
    #expect(model.sidebarSelection == [.recents])
    #expect(model.openedMedia == nil)
    await model.selectSidebarDestinations([.recents, .folder(children[1].id)])
    #expect(model.sidebarSelection == [.folder(children[1].id)])
    #expect(model.selectedFolder?.id == children[1].id)
    await model.selectSidebarDestinations(selection.union([.recents, .duplicates, .people]))
    #expect(model.sidebarSelection == selection)
  }

  @Test(arguments: [MediaBrowserDestination.recents, .duplicates, .people, .personSearch])
  func folderDuplicatesReuseTheScanFollowFoldersAndExitForAggregates(
    destination: MediaBrowserDestination
  ) async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let children = ["A", "B", "Empty"].map { name in
      MediaFolder(
        id: .init(url: url.appending(path: name)), name: name,
        path: url.appending(path: name).path, children: nil)
    }
    let tree = MediaFolder(
      id: .init(url: url), name: folder.name, path: folder.path, children: children)
    let items = ["A/1.png", "A/2.png", "B/1.png", "B/2.png", "A/other.png"].map { path in
      MediaItem(
        id: .init(url: url.appending(path: path)), name: path, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: path)
    }
    let group = MediaSection(id: items[0].id, title: "Group 1", items: Array(items.prefix(4)))
    let scannedTree = MediaFolder(
      id: tree.id, name: tree.name, path: tree.path, children: Array(children.prefix(2)))
    let empty = MediaBrowserSnapshot(folderTree: scannedTree, selectedFolder: nil, mediaItems: [])
    let duplicates = MediaBrowserSnapshot(
      folderTree: scannedTree, selectedFolder: nil, mediaItems: [], sections: [group])
    let (stream, continuation) = AsyncThrowingStream<MediaBrowserSnapshot, any Error>.makeStream()
    defer { continuation.finish() }
    continuation.yield(empty)
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: items),
      duplicateStream: stream)
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    await model.run()
    await model.selectDestination(.folder(children[0].id))
    await model.setShowsFolderDuplicates(true)
    #expect(model.showsFolderDuplicates)
    #expect(model.isScanningDuplicates)
    #expect(model.mediaItems.isEmpty)
    continuation.yield(duplicates)
    for _ in 0..<200 where model.mediaItems.isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.selectedDestination == .folder(children[0].id))
    #expect(model.selectedFolder == children[0])
    #expect(model.selectedDestinationName == "A")
    #expect(model.mediaItems == Array(items.prefix(2)))
    #expect(model.mediaSections.first?.title == "A · Group 1 · 2 Pictures")
    #expect(model.duplicateGroupCount == 1)
    await model.activateMedia(items[0])
    await model.navigate(.next)
    #expect(model.openedMedia?.item.id == items[1].id)
    await model.navigate(.next)
    #expect(model.openedMedia?.item.id == items[0].id)
    await model.selectDestination(.folder(children[1].id))
    #expect(model.showsFolderDuplicates)
    #expect(model.selectedDestination == .folder(children[1].id))
    #expect(model.selectedFolder == children[1])
    #expect(model.mediaItems == Array(items[2...3]))
    #expect(model.openedMedia == nil)
    #expect(model.selectedMediaID == nil)
    await model.selectDestination(.folder(children[2].id))
    #expect(model.showsFolderDuplicates)
    #expect(model.selectedDestination == .folder(children[2].id))
    #expect(model.selectedFolder == children[2])
    #expect(model.mediaItems.isEmpty)
    continuation.yield(duplicates)
    await Task.yield()
    #expect(model.selectedDestination == .folder(children[2].id))
    #expect(model.duplicateGroupCount == 1)
    await model.selectDestination(.folder(children[0].id))
    await model.setShowsFolderDuplicates(false)
    #expect(!model.isShowingDuplicates)
    #expect(model.mediaItems == [items[0], items[1], items[4]])
    await model.setShowsFolderDuplicates(true)
    continuation.finish()
    for _ in 0..<200 where model.isScanningDuplicates {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.isScanningDuplicates)
    #expect(await repository.duplicateScanCount == 1)
    await model.selectDestination(destination)
    #expect(!model.showsFolderDuplicates)
    #expect(model.selectedDestination == destination)
    if destination == .duplicates { #expect(model.mediaSections == [group]) }
    await model.setShowsFolderDuplicates(true)
    #expect(!model.showsFolderDuplicates)
    await model.selectDestination(.folder(children[0].id))
    #expect(!model.isShowingDuplicates)
    #expect(model.mediaItems == [items[0], items[1], items[4]])
    #expect(await repository.duplicateScanCount == 1)
  }

  @Test
  func keepingBestFolderDuplicateLeavesCopiesInOtherFoldersUntouched() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: folder.name, path: folder.path, children: nil)
    let items = ["1.png", "2.png", "Other/3.png"].map { path in
      MediaItem(
        id: .init(url: url.appending(path: path)), name: path, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: path)
    }
    let group = MediaSection(id: items[0].id, title: "Group 1", items: items)
    let original = MediaBrowserSnapshot(
      folderTree: tree, selectedFolder: nil, mediaItems: [], sections: [group])
    let initial = AsyncThrowingStream<MediaBrowserSnapshot, any Error> {
      $0.yield(original)
      $0.finish()
    }
    let (verification, continuation) = AsyncThrowingStream<MediaBrowserSnapshot, any Error>
      .makeStream()
    defer { continuation.finish() }
    let repository = MutableTestMediaRepository(
      snapshot: original, duplicateStreams: [initial, verification])
    let recorder = DuplicateCleanupRecorder()
    let qualities = Dictionary(
      uniqueKeysWithValues: items.enumerated().map { index, item in
        (
          item.id,
          DuplicateImageQuality(
            pixelCount: Int64(index + 1) * 100, bitDepth: 8, isLossless: true, fileSize: 100)
        )
      })
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(
        cleanupRecorder: recorder, imageQualities: qualities),
      folderAccess: TestMediaFolderAccessRepository(), fileChangeRefreshDelay: .zero)
    await model.selectDestination(.folder(tree.id))
    await model.setShowsFolderDuplicates(true)
    for _ in 0..<200 where model.preferredDuplicateIDs.isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.preferredDuplicateIDs == [items[1].id])
    await model.keepBestCopy(in: try #require(model.mediaSections.first))
    #expect(await recorder.removed == [items[0].id.url])
    #expect(model.alertMessage == nil)
    #expect(model.mediaItems.isEmpty)
    #expect(model.showsFolderDuplicates)
    #expect(model.selectedDestination == .folder(tree.id))
    continuation.yield(
      MediaBrowserSnapshot(
        folderTree: tree, selectedFolder: nil, mediaItems: [],
        sections: [MediaSection(id: group.id, title: group.title, items: Array(items.suffix(2)))]))
    continuation.finish()
    for _ in 0..<200 where model.isScanningDuplicates {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaItems.isEmpty)
    await model.selectDestination(.duplicates)
    #expect(model.mediaItems == Array(items.suffix(2)))
  }

  @Test
  func mergingPeopleRemovesTheSplitCardAndKeepsItsOpenAlbumAndSelection() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: folder.name, path: folder.path, children: nil)
    let items = ["Alice/1.png", "Holiday/2.png"].map { path in
      MediaItem(
        id: .init(url: url.appending(path: path)), name: path, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: path)
    }
    let first = PersonGroup(
      id: UUID(), name: "Alice", thumbnail: testFaceThumbnailSource(),
      items: [items[0]])
    let split = PersonGroup(
      id: UUID(), name: "Holiday", thumbnail: first.thumbnail, items: [items[1]])
    let (stream, continuation) = AsyncThrowingStream<[PersonGroup], any Error>.makeStream()
    let people = TestPeopleRepository(streams: [stream])
    let media = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: tree, selectedFolder: nil, mediaItems: items), observesChanges: true)
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: media, peopleRepository: people,
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    let run = Task { await model.run() }
    defer {
      run.cancel()
      continuation.finish()
    }
    continuation.yield([first, split])
    for _ in 0..<200 where model.people.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    await model.selectDestination(.person(split.id))
    await model.activateMedia(items[1])
    #expect(model.selectedMediaID == items[1].id)
    continuation.yield([
      PersonGroup(
        id: first.id, name: first.name, thumbnail: first.thumbnail,
        items: items, mergedGroupIDs: [split.id])
    ])
    for _ in 0..<200 where model.people.count > 1 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.isScanningPeople)
    #expect(model.people.map(\.id) == [first.id])
    #expect(model.selectedDestination == .person(first.id))
    #expect(model.selectedDestinationName == "Alice")
    #expect(model.mediaItems == items)
    #expect(model.selectedMediaID == items[1].id)
    #expect(model.openedMedia?.item.id == items[1].id)
    continuation.finish()
    for _ in 0..<200 where model.isScanningPeople { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.selectedDestination == .person(first.id))
    #expect(model.openedMedia?.item.id == items[1].id)
  }

  @Test
  func peopleScanStartsInBackgroundReusesViewerAndRefreshesAfterFileChanges() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: folder.name, path: folder.path, children: nil)
    let items = ["Alice/1.png", "Holiday/2.png"].map { path in
      MediaItem(
        id: .init(url: url.appending(path: path)), name: path, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: path)
    }
    let id = UUID()
    func person(_ items: [MediaItem]) -> PersonGroup {
      PersonGroup(
        id: id, name: "Alice", thumbnail: testFaceThumbnailSource(), items: items)
    }
    let (stream, continuation) = AsyncThrowingStream<[PersonGroup], any Error>.makeStream()
    let (rescan, rescanContinuation) = AsyncThrowingStream<[PersonGroup], any Error>.makeStream()
    let people = TestPeopleRepository(streams: [stream, rescan])
    let media = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: items),
      observesChanges: true)
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: media, peopleRepository: people,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .zero)
    let run = Task { await model.run() }
    defer {
      run.cancel()
      continuation.finish()
      rescanContinuation.finish()
    }
    for _ in 0..<200 where await people.scanCount == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await people.scanCount == 1)
    #expect(model.selectedDestination == .recents)
    continuation.yield([person([items[0]])])
    for _ in 0..<200 where model.people.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.isScanningPeople)
    await model.selectDestination(.person(id))
    #expect(model.selectedDestinationName == "Alice")
    #expect(model.selectedFolder == nil)
    #expect(model.mediaItems == [items[0]])
    await model.activateMedia(items[0])
    continuation.yield([person(items)])
    for _ in 0..<200 where model.mediaItems.count < 2 {
      try await Task.sleep(for: .milliseconds(5))
    }
    await model.navigate(.next)
    #expect(model.openedMedia?.item.id == items[1].id)
    await model.navigate(.next)
    #expect(model.openedMedia?.item.id == items[0].id)
    model.closeMedia()
    model.selectMedia(items[0])
    continuation.yield([person([items[1]])])
    continuation.finish()
    for _ in 0..<200 where model.isScanningPeople { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.people.count == 1)
    #expect(model.mediaItems == [items[1]])
    #expect(model.selectedMediaID == nil)
    await media.sendFileChange()
    for _ in 0..<200 where await people.scanCount < 2 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await people.scanCount == 2)
    rescanContinuation.yield([])
    rescanContinuation.finish()
    for _ in 0..<200 where model.isScanningPeople { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.people.isEmpty)
    #expect(model.selectedDestination == .people)
    #expect(model.mediaItems.isEmpty)
    run.cancel()
    await run.value
    #expect(!model.isScanningPeople)
  }

  @Test
  func peopleFailureCanBeRetriedAndClosingWindowCancelsTheScan() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: folder.name, path: folder.path, children: nil)
    let failed = AsyncThrowingStream<[PersonGroup], any Error> {
      $0.finish(throwing: MediaRepositoryError.invalidPicture)
    }
    let (retry, continuation) = AsyncThrowingStream<[PersonGroup], any Error>.makeStream()
    let people = TestPeopleRepository(streams: [failed, retry])
    let media = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: []),
      observesChanges: true)
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: media, peopleRepository: people,
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    let run = Task { await model.run() }
    defer {
      run.cancel()
      continuation.finish()
    }
    for _ in 0..<200 where model.peopleErrorMessage == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.peopleErrorMessage != nil)
    await model.selectDestination(.people)
    await model.retry()
    #expect(model.peopleErrorMessage == nil)
    #expect(model.isScanningPeople)
    await model.selectDestination(.recents)
    #expect(model.isScanningPeople)
    run.cancel()
    await run.value
    #expect(!model.isScanningPeople)
    var terminated = false
    for _ in 0..<200 {
      if case .terminated = continuation.yield([]) {
        terminated = true
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(terminated)
  }

  @Test
  func personSearchChoosesOneFaceReusesViewerAndRefreshesWithoutLosingSelection() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: folder.name, path: folder.path, children: nil)
    let items = ["Alice/1.png", "Holiday/2.png"].map { path in
      MediaItem(
        id: .init(url: url.appending(path: path)), name: path, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: path)
    }
    let (stream, continuation) = AsyncThrowingStream<[MediaItem], any Error>.makeStream()
    let (rescan, rescanContinuation) = AsyncThrowingStream<[MediaItem], any Error>.makeStream()
    let thumbnail = testFaceThumbnailSource()
    let people = TestPeopleRepository(
      referenceFaces: [
        DetectedFace(embedding: [1, 0], thumbnail: thumbnail),
        DetectedFace(embedding: [0, 1], thumbnail: thumbnail),
      ], searchStreams: [stream, rescan])
    let media = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: items),
      observesChanges: true)
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: media, peopleRepository: people,
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .zero)
    let run = Task { await model.run() }
    defer {
      run.cancel()
      continuation.finish()
      rescanContinuation.finish()
    }
    for _ in 0..<200 where model.isLoading { try await Task.sleep(for: .milliseconds(5)) }
    await model.searchForPerson(using: URL(fileURLWithPath: "/Reference/group.png"))
    for _ in 0..<200 where model.isSearchingPerson { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.selectedDestination == .personSearch)
    #expect(model.selectedDestinationName == "Search for person")
    #expect(model.personSearchFaces.count == 2)
    #expect(model.personSearchFaceIndex == nil)
    #expect(await people.searchCount == 0)
    model.selectPersonSearchFace(at: 1)
    for _ in 0..<200 where await people.searchCount == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await people.searchedEmbeddings == [[0, 1]])
    continuation.yield([items[0]])
    for _ in 0..<200 where model.mediaItems.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.isSearchingPerson)
    #expect(model.selectedFolder == nil)
    await model.activateMedia(items[0])
    continuation.yield(items)
    continuation.finish()
    for _ in 0..<200 where model.isSearchingPerson { try await Task.sleep(for: .milliseconds(5)) }
    await model.navigate(.next)
    #expect(model.openedMedia?.item.id == items[1].id)
    await model.navigate(.next)
    #expect(model.openedMedia?.item.id == items[0].id)
    model.closeMedia()
    model.selectMedia(items[0])
    await media.sendFileChange()
    for _ in 0..<200 where await people.searchCount < 2 {
      try await Task.sleep(for: .milliseconds(5))
    }
    rescanContinuation.yield([])
    await Task.yield()
    #expect(model.selectedMediaID == items[0].id)
    rescanContinuation.yield(items)
    rescanContinuation.finish()
    for _ in 0..<200 where model.isSearchingPerson { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.selectedMediaID == items[0].id)
    #expect(model.mediaItems == items)
    await model.selectDestination(.people)
    #expect(model.selectedMediaID == nil)
    run.cancel()
    await run.value
  }

  @Test
  func singleReferenceFaceStartsAutomaticallyAndLeavingCancelsLateResults() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: folder.name, path: folder.path, children: nil)
    let (stream, continuation) = AsyncThrowingStream<[MediaItem], any Error>.makeStream()
    defer { continuation.finish() }
    let people = TestPeopleRepository(
      referenceFaces: [DetectedFace(embedding: [1, 0], thumbnail: testFaceThumbnailSource())],
      searchStreams: [stream])
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: TestMediaRepository(
        snapshot: .init(folderTree: tree, selectedFolder: nil, mediaItems: [])),
      peopleRepository: people, fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository())
    await model.searchForPerson(using: url.appending(path: "reference.png"))
    for _ in 0..<200 where await people.searchCount == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.personSearchFaceIndex == 0)
    #expect(model.isSearchingPerson)
    await model.selectDestination(.people)
    #expect(!model.isSearchingPerson)
    continuation.finish(throwing: CocoaError(.fileReadUnknown))
    try await Task.sleep(for: .milliseconds(10))
    #expect(model.selectedDestination == .people)
    #expect(model.personSearchErrorMessage == nil)
  }

  @Test
  func personSearchReportsMissingFacesAndRetriesAnalysisFailures() async throws {
    let url = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let tree = MediaFolder(id: .init(url: url), name: folder.name, path: folder.path, children: nil)
    let failed = AsyncThrowingStream<[MediaItem], any Error> {
      $0.finish(throwing: CocoaError(.fileReadUnknown))
    }
    let empty = AsyncThrowingStream<[MediaItem], any Error> {
      $0.yield([])
      $0.finish()
    }
    let people = TestPeopleRepository(
      referenceFaces: [DetectedFace(embedding: [1, 0], thumbnail: testFaceThumbnailSource())],
      searchStreams: [failed, empty])
    let media = TestMediaRepository(
      snapshot: .init(folderTree: tree, selectedFolder: nil, mediaItems: []))
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: media, peopleRepository: people,
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    await model.searchForPerson(using: url.appending(path: "reference.png"))
    for _ in 0..<200 where model.personSearchErrorMessage == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.personSearchErrorMessage != nil)
    #expect(!model.isSearchingPerson)
    await model.retry()
    for _ in 0..<200 where model.isSearchingPerson { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.personSearchErrorMessage == nil)
    #expect(model.mediaItems.isEmpty)
    #expect(await people.searchCount == 2)
    let noFaceModel = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: media, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    await noFaceModel.searchForPerson(using: url.appending(path: "landscape.png"))
    for _ in 0..<200 where noFaceModel.isSearchingPerson {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(noFaceModel.personSearchErrorMessage != nil)
    #expect(noFaceModel.personSearchFaceIndex == nil)
    #expect(noFaceModel.mediaItems.isEmpty)
  }

  @Test
  func verificationScanRetainsKnownGroupsSelectionAndThumbnailsUntilCompletion() async throws {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["a.png", "b.png", "c.png", "d.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let first = MediaSection(id: items[0].id, title: "Group 1", items: Array(items.prefix(2)))
    let second = MediaSection(id: items[2].id, title: "Group 2", items: Array(items.suffix(2)))
    let original = MediaBrowserSnapshot(
      folderTree: tree, selectedFolder: nil, mediaItems: [], sections: [first, second])
    let (initial, initialContinuation) = AsyncThrowingStream<MediaBrowserSnapshot, any Error>
      .makeStream()
    initialContinuation.yield(original)
    initialContinuation.finish()
    let (verification, continuation) = AsyncThrowingStream<MediaBrowserSnapshot, any Error>
      .makeStream()
    defer { continuation.finish() }
    let repository = MutableTestMediaRepository(
      snapshot: original, duplicateStreams: [initial, verification])
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(), folderAccess: TestMediaFolderAccessRepository()
    )
    await model.selectDestination(.duplicates)
    await model.loadThumbnail(for: items[0])
    await model.loadThumbnail(for: items[2])
    model.selectMedia(items[2])
    await model.retry()
    let revision = model.mediaItemsRevision
    continuation.yield(
      MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: [], sections: [first])
    )
    for _ in 0..<200 where model.mediaItemsRevision == revision {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaItemsRevision > revision)
    #expect(model.isScanningDuplicates)
    #expect(model.mediaSections == [first, second])
    #expect(model.selectedMediaID == items[2].id)
    #expect(model.thumbnail(for: items[2]) != nil)
    continuation.yield(
      MediaBrowserSnapshot(
        folderTree: tree, selectedFolder: nil, mediaItems: [], sections: [second]))
    continuation.finish()
    for _ in 0..<200 where model.mediaSections != [second] {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaSections == [second])
    #expect(model.selectedMediaID == items[2].id)
    #expect(model.thumbnail(for: items[2]) != nil)
    #expect(model.thumbnail(for: items[0]) == nil)
  }

  @Test
  func fileChangeDuringScanDoesNotSuppressNewGroups() async throws {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["a.png", "b.png", "c.png", "d.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let first = MediaSection(id: items[0].id, title: "Group 1", items: Array(items.prefix(2)))
    let second = MediaSection(id: items[2].id, title: "Group 2", items: Array(items.suffix(2)))
    let partial = MediaBrowserSnapshot(
      folderTree: tree, selectedFolder: nil, mediaItems: [], sections: [first])
    let complete = MediaBrowserSnapshot(
      folderTree: tree, selectedFolder: nil, mediaItems: [], sections: [first, second])
    let (stream, continuation) = AsyncThrowingStream<MediaBrowserSnapshot, any Error>.makeStream()
    let repository = MutableTestMediaRepository(
      snapshot: complete, observesChanges: true, duplicateStreams: [stream])
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(), fileChangeRefreshDelay: .zero)
    let runTask = Task { await model.run() }
    defer {
      continuation.finish()
      runTask.cancel()
    }
    continuation.yield(partial)
    for _ in 0..<200 where model.duplicateGroupCount == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    await model.selectDestination(.duplicates)
    #expect(model.mediaSections == [first])
    let revision = model.mediaItemsRevision
    await repository.sendFileChange()
    for _ in 0..<200 where model.mediaItemsRevision == revision {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaItemsRevision > revision)
    continuation.yield(complete)
    for _ in 0..<200 where model.mediaSections.count != 2 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaSections == [first, second])
    #expect(model.isScanningDuplicates)
    continuation.finish()
    for _ in 0..<200 where model.isScanningDuplicates {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.isScanningDuplicates)
    #expect(model.duplicateGroupCount == 2)
    runTask.cancel()
    await runTask.value
  }

  @Test
  func cleanupUpdatesResultsAndReleasesButtonsBeforeVerificationScanFinishes() async throws {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["a.png", "b.png", "c.png", "d.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let sections = [
      MediaSection(id: items[0].id, title: "Group 1", items: Array(items.prefix(2))),
      MediaSection(id: items[2].id, title: "Group 2", items: Array(items.suffix(2))),
    ]
    let original = MediaBrowserSnapshot(
      folderTree: tree, selectedFolder: nil, mediaItems: items, sections: sections)
    let (initial, initialContinuation) = AsyncThrowingStream<MediaBrowserSnapshot, any Error>
      .makeStream()
    initialContinuation.yield(original)
    initialContinuation.finish()
    let (verification, verificationContinuation) = AsyncThrowingStream<
      MediaBrowserSnapshot, any Error
    >.makeStream()
    defer { verificationContinuation.finish() }
    let repository = MutableTestMediaRepository(
      snapshot: original, duplicateStreams: [initial, verification])
    let recorder = DuplicateCleanupRecorder()
    let quality = DuplicateImageQuality(
      pixelCount: 100, bitDepth: 8, isLossless: true, fileSize: 100)
    let operations = TestFileOperationRepository(
      cleanupRecorder: recorder,
      imageQualities: Dictionary(uniqueKeysWithValues: items.map { ($0.id, quality) }))
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: operations, folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .zero)
    await model.selectDestination(.duplicates)
    await model.activateMedia(items[1])
    let cleanup = Task { await model.keepBestCopy(in: sections[0]) }
    for _ in 0..<200 {
      if await recorder.removed.count == 1, !model.isCleaningDuplicates { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.isCleaningDuplicates)
    #expect(model.isScanningDuplicates)
    #expect(model.mediaSections == [sections[1]])
    #expect(model.mediaItems == Array(items.suffix(2)))
    #expect(model.duplicateGroupCount == 1)
    #expect(model.openedMedia == nil)
    #expect(model.selectedMediaID == nil)
    verificationContinuation.yield(
      MediaBrowserSnapshot(
        folderTree: tree, selectedFolder: nil,
        mediaItems: [], sections: [sections[1]]))
    verificationContinuation.finish()
    await cleanup.value
    for _ in 0..<200 where model.isScanningDuplicates {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.isScanningDuplicates)
    #expect(model.mediaSections == [sections[1]])
  }

  @Test(arguments: [0, 1, 2, 3])
  func keepsHighestQualityCopyAndStopsOnUnavailableTrashChangedFilesOrPartialFailure(scenario: Int)
    async
  {
    let trashUnavailable = scenario == 1
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["small.png", "large.jpg", "large.png", "deep.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let qualities = [
      DuplicateImageQuality(pixelCount: 100, bitDepth: 8, isLossless: true, fileSize: 9999),
      DuplicateImageQuality(pixelCount: 400, bitDepth: 8, isLossless: false, fileSize: 9999),
      DuplicateImageQuality(pixelCount: 400, bitDepth: 8, isLossless: true, fileSize: 900),
      DuplicateImageQuality(pixelCount: 400, bitDepth: 16, isLossless: true, fileSize: 800),
    ]
    let recorder = DuplicateCleanupRecorder(failAfter: scenario == 3 ? 1 : nil)
    let operations = TestFileOperationRepository(
      cleanupRecorder: recorder,
      imageQualities: Dictionary(uniqueKeysWithValues: zip(items.map(\.id), qualities)),
      trashUnavailable: trashUnavailable,
      changedItemID: scenario == 2 ? items[3].id : nil)
    let section = MediaSection(id: items[0].id, title: "Group 1", items: items)
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: TestMediaRepository(
        snapshot: MediaBrowserSnapshot(
          folderTree: tree,
          selectedFolder: nil, mediaItems: items, sections: [section])),
      peopleRepository: TestPeopleRepository(),
      fileOperations: operations, folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .zero)
    await model.selectDestination(.duplicates)
    for _ in 0..<200 where model.preferredDuplicateIDs.isEmpty {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.preferredDuplicateIDs == [items[3].id])
    model.selectMedia(items[0])
    #expect(model.preferredDuplicateIDs == [items[3].id])
    await model.selectDestination(.recents)
    #expect(model.preferredDuplicateIDs.isEmpty)
    await model.selectDestination(.duplicates)
    await model.keepBestCopy(in: section)
    let removed = await recorder.removed
    let expected =
      scenario == 0
      ? Array(items.prefix(3)).reversed().map(\.id.url)
      : scenario == 3 ? [items[2].id.url] : []
    #expect(removed == expected)
    #expect(!removed.contains(items[3].id.url))
    #expect((model.alertMessage != nil) == (scenario != 0))
    #expect(!model.isCleaningDuplicates)
  }

  @Test
  func displaysPartialGroupsWhileScanIsStillRunning() async throws {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["a.png", "b.png", "c.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name,
        kind: .picture, dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let (stream, continuation) = AsyncThrowingStream<MediaBrowserSnapshot, any Error>.makeStream()
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: []),
      duplicateStream: stream
    )
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository()
    )
    await model.run()
    let navigation = Task { await model.selectDestination(.duplicates) }
    continuation.yield(
      MediaBrowserSnapshot(
        folderTree: tree, selectedFolder: nil, mediaItems: Array(items.prefix(2))))
    for _ in 0..<200 where model.mediaItems.count != 2 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaItems.count == 2)
    #expect(model.isScanningDuplicates)
    #expect(!model.isLoading)
    #expect(model.duplicateGroupCount == 1)
    model.selectMedia(items[0])
    continuation.yield(
      MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: items))
    for _ in 0..<200 where model.mediaItems.count != 3 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaItems.count == 3)
    #expect(model.selectedMediaID == items[0].id)
    #expect(model.isScanningDuplicates)
    continuation.finish()
    await navigation.value
    for _ in 0..<200 where model.isScanningDuplicates {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.isScanningDuplicates)
    #expect(model.duplicateGroupCount == 1)
  }

  @Test
  func changesDuringBackgroundScanAreRescannedWithoutNavigationCancellingTheScan() async throws {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["a.png", "b.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name,
        kind: .picture, dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: []),
      duplicateDelay: .milliseconds(100), observesChanges: true
    )
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(), fileChangeRefreshDelay: .zero
    )
    let runTask = Task { await model.run() }
    defer { runTask.cancel() }
    for _ in 0..<200 {
      if await repository.duplicateScanCount > 0, !model.isLoading { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await repository.duplicateScanCount == 1)
    let navigationTask = Task { await model.selectDestination(.duplicates) }
    await Task.yield()
    await model.selectDestination(.recents)
    await repository.setMediaItems(items)
    await navigationTask.value
    for _ in 0..<200 where model.duplicateGroupCount == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.selectedDestination == .recents)
    #expect(model.duplicateGroupCount == 1)
    #expect(await repository.duplicateScanCount == 2)
    await model.selectDestination(.duplicates)
    #expect(model.mediaItems == items)
    #expect(await repository.duplicateScanCount == 2)
    runTask.cancel()
    await runTask.value
  }

  @Test
  func scansOnOpeningAndKeepsBadgeUntilASuccessfulEmptyScan() async throws {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["a.png", "b.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name,
        kind: .picture, dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(folderTree: tree, selectedFolder: nil, mediaItems: items),
      duplicateDelay: .milliseconds(40), observesChanges: true
    )
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(), fileChangeRefreshDelay: .zero
    )
    let runTask = Task { await model.run() }
    defer { runTask.cancel() }
    for _ in 0..<200 where model.isLoading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!model.isLoading)
    #expect(model.selectedDestination == .recents)
    for _ in 0..<200 where model.duplicateGroupCount == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.duplicateGroupCount == 1)
    #expect(await repository.duplicateScanCount == 1)

    await model.selectDestination(.duplicates)
    #expect(model.duplicateGroupCount == 1)
    #expect(await repository.duplicateScanCount == 1)
    await model.selectDestination(.recents)
    #expect(model.duplicateGroupCount == 1)
    await repository.setDuplicateFailure(true)
    await model.selectDestination(.duplicates)
    await model.retry()
    for _ in 0..<200 where model.errorMessage == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.errorMessage != nil)
    #expect(model.duplicateGroupCount == 1)

    await model.selectDestination(.recents)
    await repository.setDuplicateFailure(false)
    await repository.setMediaItems([])
    for _ in 0..<200 where model.duplicateGroupCount != 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.duplicateGroupCount == 0)
    #expect(model.selectedDestination == .recents)
    runTask.cancel()
    await runTask.value
  }

  @Test
  func duplicatesReuseSelectionViewerNavigationAndMutationRefresh() async throws {
    let rootURL = URL(fileURLWithPath: "/Pictures")
    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    let tree = MediaFolder(
      id: MediaFolder.ID(url: rootURL), name: "Pictures", path: rootURL.path, children: nil)
    let items = ["a.png", "b.png"].map { name in
      MediaItem(
        id: MediaItem.ID(url: rootURL.appending(path: name)), name: name,
        kind: .picture, dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: name)
    }
    let sections = [MediaSection(id: items[0].id, title: "Group 1", items: items)]
    let repository = MutableTestMediaRepository(
      snapshot: MediaBrowserSnapshot(
        folderTree: tree, selectedFolder: nil, mediaItems: items, sections: sections
      ))
    let model = MediaBrowserFeatureModel(
      folder: folder, mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(),
      folderAccess: TestMediaFolderAccessRepository(), fileChangeRefreshDelay: .zero
    )
    await model.selectDestination(.duplicates)
    #expect(model.selectedDestination == .duplicates)
    #expect(model.selectedDestinationName == "Duplicates")
    #expect(model.selectedFolder == nil)
    #expect(model.mediaSections == sections)
    model.selectMedia(items[0])
    #expect(model.openedMedia == nil)
    await model.activateMedia(items[0])
    await model.navigate(.next)
    #expect(model.openedMedia?.item == items[1])
    await model.navigate(.next)
    #expect(model.openedMedia?.item == items[0])
    await model.selectSortOption(.name)
    #expect(model.selectedMediaID == items[0].id)
    await repository.setMediaItems([])
    await model.moveToTrash(.media(items[0]))
    for _ in 0..<200 where !model.mediaSections.isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.mediaSections.isEmpty)
    #expect(model.selectedMediaID == nil)
    #expect(model.openedMedia == nil)
    #expect(model.selectedDestination == .duplicates)
  }

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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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

    await model.loadFileOperationCapabilities(for: .media(item))
    await model.retry()
    #expect(model.fileOperationCapabilities[item.id.url]?.canModify == true)

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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
  func rotatesAnEditablePictureImmediatelyAndCanRotateItAgain() async {
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
      )
    )
    let recorder = CropCallRecorder()
    let model = MediaBrowserFeatureModel(
      folder: folder,
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
      fileOperations: TestFileOperationRepository(cropRecorder: recorder),
      folderAccess: TestMediaFolderAccessRepository(),
      fileChangeRefreshDelay: .zero
    )

    await model.run()
    await model.activateMedia(item)
    await model.rotatePictureClockwise()
    #expect(await recorder.rotations().isEmpty)

    await model.loadFileOperationCapabilities(for: .media(item))
    await model.rotatePictureClockwise()
    await model.rotatePictureClockwise()

    #expect(await recorder.rotations() == [item, item])
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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
      peopleRepository: TestPeopleRepository(),
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
      peopleRepository: TestPeopleRepository(),
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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
      mediaRepository: repository, peopleRepository: TestPeopleRepository(),
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
        peopleRepository: TestPeopleRepository(),
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
  private let duplicateDelay: Duration
  private let duplicateStream: AsyncThrowingStream<MediaBrowserSnapshot, any Error>?
  private var duplicateStreams: [AsyncThrowingStream<MediaBrowserSnapshot, any Error>]
  private let changes: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private var duplicateFailure = false
  private(set) var duplicateScanCount = 0

  init(
    snapshot: MediaBrowserSnapshot, duplicateDelay: Duration = .zero, observesChanges: Bool = false,
    duplicateStream: AsyncThrowingStream<MediaBrowserSnapshot, any Error>? = nil,
    duplicateStreams: [AsyncThrowingStream<MediaBrowserSnapshot, any Error>] = []
  ) {
    currentSnapshot = snapshot
    self.duplicateDelay = duplicateDelay
    self.duplicateStream = duplicateStream
    self.duplicateStreams = duplicateStreams
    (changes, continuation) = AsyncStream<Void>.makeStream()
    if !observesChanges { continuation.finish() }
  }

  func duplicateSnapshots(in rootFolder: Folder, sort: MediaSort) async -> AsyncThrowingStream<
    MediaBrowserSnapshot, any Error
  > {
    duplicateScanCount += 1
    if !duplicateStreams.isEmpty { return duplicateStreams.removeFirst() }
    if let duplicateStream { return duplicateStream }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          continuation.yield(
            try await self.snapshot(of: rootFolder, destination: .duplicates, sort: sort))
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func sendFileChange() { continuation.yield() }

  func setDuplicateFailure(_ value: Bool) { duplicateFailure = value }

  func setMediaItems(_ mediaItems: [MediaItem]) {
    currentSnapshot = MediaBrowserSnapshot(
      folderTree: currentSnapshot.folderTree,
      selectedFolder: currentSnapshot.selectedFolder,
      mediaItems: mediaItems
    )
    continuation.yield()
  }

  func snapshot(
    of rootFolder: Folder,
    destination: MediaBrowserDestination,
    sort: MediaSort
  ) async throws -> MediaBrowserSnapshot {
    if destination == .duplicates {
      let snapshot = currentSnapshot
      try await Task.sleep(for: duplicateDelay)
      if duplicateFailure { throw MediaRepositoryError.invalidPicture }
      return snapshot
    }
    if case .folders(let ids) = destination {
      let sections = (currentSnapshot.folderTree.children ?? [])
        .filter { ids.contains($0.id) }.sorted { $0.name < $1.name }.map { folder in
          MediaSection(
            id: .init(url: folder.id.url), title: folder.name,
            items: currentSnapshot.mediaItems.filter {
              $0.id.url.deletingLastPathComponent() == folder.id.url
            })
        }
      return MediaBrowserSnapshot(
        folderTree: currentSnapshot.folderTree, selectedFolder: nil, mediaItems: [],
        sections: sections)
    }
    if case .folder(let id) = destination {
      let selectedFolder = MediaFolder(
        id: id, name: id.url.lastPathComponent, path: id.url.path, children: nil)
      return MediaBrowserSnapshot(
        folderTree: currentSnapshot.folderTree, selectedFolder: selectedFolder,
        mediaItems: currentSnapshot.mediaItems.filter {
          $0.id.url.deletingLastPathComponent().standardizedFileURL.pathComponents
            == id.url.standardizedFileURL.pathComponents
        })
    }
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

  func transfer(_ transfer: MediaTransfer, in rootFolder: Folder) async throws {}

  func updates(in folder: Folder) async -> AsyncStream<Void> {
    changes
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
    if destination == .duplicates {
      return MediaBrowserSnapshot(
        folderTree: currentSnapshot.folderTree, selectedFolder: nil, mediaItems: [])
    }
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
    if destination != .duplicates { currentSnapshotCount += 1 }
    switch destination {
    case .recents, .duplicates, .people, .person, .personSearch, .folders:
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

private actor DuplicateCleanupRecorder {
  private(set) var removed: [URL] = []
  private let failAfter: Int?
  init(failAfter: Int? = nil) { self.failAfter = failAfter }
  func record(_ url: URL) throws {
    if removed.count == failAfter { throw FileOperationRepositoryError.readOnlyDestination }
    removed.append(url)
  }
}

private struct TestFileOperationRepository: FileOperationRepository {
  var cleanupRecorder: DuplicateCleanupRecorder? = nil
  var imageQualities: [MediaItem.ID: DuplicateImageQuality] = [:]
  var trashUnavailable = false
  var changedItemID: MediaItem.ID? = nil

  func imageQuality(for item: MediaItem, in rootFolder: Folder) async throws
    -> DuplicateImageQuality
  {
    guard let quality = imageQualities[item.id] else {
      throw FileOperationRepositoryError.invalidTarget
    }
    return quality
  }

  var cropRecorder: CropCallRecorder?
  var cropResultURL: URL?

  #if os(macOS)
    var openingApplications: [FileOpeningApplication] = []
  #endif

  func capabilities(
    for target: FileOperationTarget,
    in rootFolder: Folder
  ) async -> FileOperationCapabilities {
    FileOperationCapabilities(
      canModify: true, canModifyContents: true, canMoveToTrash: !trashUnavailable)
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

  func rotatePictureClockwise(_ item: MediaItem, in rootFolder: Folder) async throws -> URL {
    await cropRecorder?.recordRotation(item)
    return item.id.url
  }

  func moveToTrash(_ target: FileOperationTarget, in rootFolder: Folder) async throws {
    try await cleanupRecorder?.record(target.url)
  }
  func delete(_ target: FileOperationTarget, in rootFolder: Folder) async throws {}

  func info(for target: FileOperationTarget, in rootFolder: Folder) async throws -> FileItemInfo {
    FileItemInfo(
      id: target.url,
      name: target.name,
      kind: "File",
      fileSize: changedItemID?.url == target.url ? 1 : nil,
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
  private var rotatedItems: [MediaItem] = []

  func record(_ call: CropCall) {
    recordedCalls.append(call)
  }

  func calls() -> [CropCall] {
    recordedCalls
  }

  func recordRotation(_ item: MediaItem) {
    rotatedItems.append(item)
  }

  func rotations() -> [MediaItem] {
    rotatedItems
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

private actor TestPeopleRepository: PeopleRepository {
  private var streams: [AsyncThrowingStream<[PersonGroup], any Error>]
  private let references: [DetectedFace]
  private var searchStreams: [AsyncThrowingStream<[MediaItem], any Error>]
  private(set) var searchedEmbeddings: [[Float]] = []
  var searchCount: Int { searchedEmbeddings.count }
  private(set) var scanCount = 0
  init(
    streams: [AsyncThrowingStream<[PersonGroup], any Error>] = [],
    referenceFaces: [DetectedFace] = [],
    searchStreams: [AsyncThrowingStream<[MediaItem], any Error>] = []
  ) {
    self.streams = streams
    self.references = referenceFaces
    self.searchStreams = searchStreams
  }
  func thumbnail(for source: FaceThumbnailSource) async throws -> MediaThumbnail {
    MediaThumbnail(image: testMediaImage())
  }
  func people(in folder: Folder) async -> AsyncThrowingStream<[PersonGroup], any Error> {
    scanCount += 1
    if !streams.isEmpty { return streams.removeFirst() }
    return AsyncThrowingStream {
      $0.yield([])
      $0.finish()
    }
  }
  func referenceFaces(at url: URL) async throws -> [DetectedFace] {
    guard !references.isEmpty else { throw PeopleRepositoryError.noReferenceFace }
    return references
  }
  func pictures(matching face: DetectedFace, in folder: Folder) async
    -> AsyncThrowingStream<[MediaItem], any Error>
  {
    searchedEmbeddings.append(face.embedding)
    if !searchStreams.isEmpty { return searchStreams.removeFirst() }
    return AsyncThrowingStream {
      $0.yield([])
      $0.finish()
    }
  }
}
