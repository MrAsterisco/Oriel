import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Oriel

struct MediaRepositoryTests {
  @Test
  func folderDuplicatesFilterMembershipKeepGroupIdentityAndOmitLocalSingletons() {
    let url = URL(fileURLWithPath: "/Library")
    let child = MediaFolder(
      id: .init(url: url.appending(path: "A")), name: "A", path: "/Library/A", children: nil)
    let tree = MediaFolder(
      id: .init(url: url), name: "Library", path: url.path, children: [child])
    let items = ["B/1.jpg", "A/1.jpg", "A/2.jpg", "A/Nested/3.jpg", "A/solo.jpg", "B/solo.jpg"]
      .map { item(path: $0, dateAdded: nil, fileSize: nil) }
    let group = MediaSection(id: items[0].id, title: "Mixed folders", items: Array(items.prefix(4)))
    let singleton = MediaSection(id: items[4].id, title: "Singleton", items: Array(items.suffix(2)))
    let snapshot = MediaBrowserSnapshot(
      folderTree: tree, selectedFolder: nil, mediaItems: [], sections: [group, singleton])
    let filtered = LocalMediaRepository().folderDuplicateSnapshot(from: snapshot, in: child.id)
    #expect(filtered.folderTree == tree)
    #expect(filtered.selectedFolder == child)
    #expect(filtered.sections.count == 1)
    #expect(filtered.sections.first?.id == group.id)
    #expect(filtered.sections.first?.title == "A · Group 1 · 2 Pictures")
    #expect(filtered.mediaItems == Array(items[1...2]))
    #expect(
      filtered.mediaItemsByID
        == Dictionary(
          uniqueKeysWithValues: items[1...2].map {
            ($0.id, $0)
          }))
    let missing = LocalMediaRepository().folderDuplicateSnapshot(
      from: snapshot, in: .init(url: url.appending(path: "Deleted")))
    #expect(missing.selectedFolder == tree)
    #expect(missing.mediaItems.isEmpty)
    #expect(snapshot.sections == [group, singleton])
  }

  @Test
  func pixelVerificationRejectsLocalChangesAndDifferentFraming() {
    let pixels = [UInt8](repeating: 128, count: 64 * 64 * 4)
    let original = DuplicateImageSample(aspectRatio: 1, pixels: pixels)
    let recompressed = DuplicateImageSample(aspectRatio: 1, pixels: pixels.map { $0 + 2 })
    #expect(LocalMediaRepository.matchingDuplicatePixels(original, recompressed))
    var changed = pixels
    for y in 16..<24 {
      for x in 16..<24 {
        for channel in 0..<3 { changed[(y * 64 + x) * 4 + channel] = 180 }
      }
    }
    #expect(
      !LocalMediaRepository.matchingDuplicatePixels(
        original, DuplicateImageSample(aspectRatio: 1, pixels: changed)))
    #expect(
      !LocalMediaRepository.matchingDuplicatePixels(
        original, DuplicateImageSample(aspectRatio: 1.2, pixels: pixels)))
  }

  @Test
  func groupingPublishesMatchesBeforeProcessingTheRemainingPictures() throws {
    let items = ["a.jpg", "b.jpg", "c.jpg"].map { item(path: $0, dateAdded: nil, fileSize: nil) }
    var processed: [Int] = []
    var updates: [[MediaItem]] = []
    _ = try LocalMediaRepository.duplicateGroups(
      items, prepare: { processed.append($0) },
      onUpdate: { groups in
        if updates.isEmpty { #expect(processed == [0, 1]) }
        updates.append(groups[0])
      }, matches: { _, _ in true }
    )
    #expect(updates.map(\.count) == [2, 3])
  }

  @Test
  func duplicateGroupsExcludeSingletonsAndDoNotChainSimilarImages() throws {
    let items = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"].map {
      item(path: $0, dateAdded: nil, fileSize: nil)
    }
    let groups = try LocalMediaRepository.duplicateGroups(items) { first, second in
      Set([first, second]) == [0, 1]
        || Set([first, second]) == [1, 2]
        || Set([first, second]) == [3, 4]
    }
    #expect(groups.map { $0.map(\.name) } == [["a.jpg", "b.jpg"], ["d.jpg", "e.jpg"]])
    #expect(try LocalMediaRepository.duplicateGroups([]) { _, _ in true }.isEmpty)
  }

  @Test
  func duplicatesUseVisionAcrossSubfoldersAndRefreshAfterRemoval() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let nestedURL = rootURL.appending(path: "Nested")
    try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let originalURL = rootURL.appending(path: "original.png")
    let copyURL = nestedURL.appending(path: "copy.jpg")
    try writeDuplicateFixture(to: originalURL, variant: false)
    try writeDuplicateFixture(to: copyURL, variant: false)
    try writeDuplicateFixture(to: rootURL.appending(path: "different.png"), variant: true)
    try Data().write(to: rootURL.appending(path: "video.mov"))
    let folder = Folder(id: Folder.ID(), name: "Test", path: rootURL.path, url: rootURL)
    let repository = LocalMediaRepository()
    let snapshot = try await repository.snapshot(
      of: folder, destination: .duplicates, sort: .initial)
    #expect(snapshot.selectedFolder == nil)
    #expect(snapshot.sections.count == 1)
    #expect(snapshot.sections.first?.title == "Nested, Test · Group 1 · 2 Pictures")
    #expect(Set(snapshot.mediaItems.map(\.relativePath)) == ["original.png", "Nested/copy.jpg"])
    #expect(snapshot.sections.flatMap(\.items) == snapshot.mediaItems)
    let operations = LocalFileOperationRepository()
    let png = try #require(snapshot.mediaItems.first { $0.id.url == originalURL })
    let jpeg = try #require(snapshot.mediaItems.first { $0.id.url == copyURL })
    let pngQuality = try await operations.imageQuality(for: png, in: folder)
    let jpegQuality = try await operations.imageQuality(for: jpeg, in: folder)
    #expect(pngQuality.pixelCount == 256 * 256)
    #expect(pngQuality.bitDepth == 8)
    #expect(pngQuality.isLossless)
    #expect(!jpegQuality.isLossless)

    try FileManager.default.removeItem(at: copyURL)
    let refreshed = try await repository.snapshot(
      of: folder, destination: .duplicates, sort: .initial)
    #expect(refreshed.mediaItems.isEmpty)
    #expect(refreshed.sections.isEmpty)
  }

  @Test
  func duplicateScanReportsUnreadablePicturesInsteadOfClaimingNoMatches() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try Data().write(to: rootURL.appending(path: "broken.jpg"))
    let folder = Folder(id: Folder.ID(), name: "Test", path: rootURL.path, url: rootURL)
    do {
      _ = try await LocalMediaRepository().snapshot(
        of: folder, destination: .duplicates, sort: .initial)
      Issue.record("Expected the unreadable image to be reported")
    } catch MediaRepositoryError.duplicateAnalysisFailed(let name, _) {
      #expect(name == "broken.jpg")
    }
  }

  private func writeDuplicateFixture(to url: URL, variant: Bool) throws {
    let context = try #require(
      CGContext(
        data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.setFillColor(CGColor(gray: variant ? 1 : 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    for index in 0..<12 {
      context.setFillColor(
        CGColor(
          red: CGFloat(index % 3) / 2, green: CGFloat(index % 5) / 4,
          blue: variant ? 0 : 1, alpha: 1
        ))
      let rect = CGRect(x: index * 19, y: (index * 37) % 220, width: 35, height: 35)
      if variant { context.fillEllipse(in: rect) } else { context.fill(rect) }
    }
    let image = try #require(context.makeImage())
    let type = url.pathExtension == "jpg" ? UTType.jpeg : UTType.png
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        url as CFURL, type.identifier as CFString, 1, nil
      ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  @Test
  func recursivelyLoadsSupportedMediaAndSortsItByDateThenPath() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let nestedURL = rootURL.appending(path: "Nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try Data().write(to: rootURL.appending(path: "cover.jpg"))
    try Data().write(to: nestedURL.appending(path: "clip.mov"))
    try Data("<svg/>".utf8).write(to: rootURL.appending(path: "unsupported.svg"))
    try Data().write(to: nestedURL.appending(path: "notes.txt"))

    let repository = LocalMediaRepository()
    let folder = Folder(
      id: Folder.ID(),
      name: "Library",
      path: rootURL.path,
      url: rootURL
    )
    let items = try await repository.recentMedia(in: folder)

    #expect(Set(items.map(\.relativePath)) == ["cover.jpg", "Nested/clip.mov"])
    #expect(items.allSatisfy { $0.dateAdded != nil })
    #expect(items.allSatisfy { $0.fileSize == 0 })
  }

  @Test
  func sortingSupportsEveryOptionAndDirection() {
    let date = Date(timeIntervalSinceReferenceDate: 100)
    let items = [
      item(path: "z.jpg", dateAdded: nil, fileSize: nil),
      item(path: "b.jpg", dateAdded: date, fileSize: 20),
      item(path: "a.jpg", dateAdded: date, fileSize: 10),
      item(path: "new.jpg", dateAdded: date.addingTimeInterval(1), fileSize: 30),
    ]

    #expect(
      paths(items, option: .mostRecent, direction: .descending)
        == ["new.jpg", "a.jpg", "b.jpg", "z.jpg"])
    #expect(
      paths(items, option: .mostRecent, direction: .ascending)
        == ["a.jpg", "b.jpg", "new.jpg", "z.jpg"])
    #expect(
      paths(items, option: .name, direction: .ascending) == [
        "a.jpg", "b.jpg", "new.jpg", "z.jpg",
      ])
    #expect(
      paths(items, option: .name, direction: .descending) == [
        "z.jpg", "new.jpg", "b.jpg", "a.jpg",
      ])
    #expect(
      paths(items, option: .size, direction: .ascending) == [
        "a.jpg", "b.jpg", "new.jpg", "z.jpg",
      ])
    #expect(
      paths(items, option: .size, direction: .descending) == [
        "new.jpg", "b.jpg", "a.jpg", "z.jpg",
      ])
  }

  @Test
  func decodesAndDownsamplesLocalPictures() async throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    let context = try #require(
      CGContext(
        data: nil,
        width: 1_000,
        height: 500,
        bitsPerComponent: 8,
        bytesPerRow: 4_000,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    let sourceImage = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(destination, sourceImage, nil)
    #expect(CGImageDestinationFinalize(destination))

    let item = MediaItem(
      id: MediaItem.ID(url: url),
      name: url.lastPathComponent,
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: url.lastPathComponent
    )
    let repository = LocalMediaRepository()

    let thumbnail = try await repository.thumbnail(for: item)
    let picture = try await repository.picture(for: item)

    #expect(thumbnail.image.cgImage.width == 480)
    #expect(thumbnail.image.cgImage.height == 240)
    #expect(picture.image.cgImage.width == 1_000)
    #expect(picture.image.cgImage.height == 500)
  }

  @Test
  func copiesMovesAndSkipsSameFolderTransfers() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let sourceURL = rootURL.appending(path: "Source", directoryHint: .isDirectory)
    let destinationURL = rootURL.appending(path: "Destination", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let pictureURL = sourceURL.appending(path: "photo.jpg")
    let videoURL = sourceURL.appending(path: "clip.mov")
    try Data("picture".utf8).write(to: pictureURL)
    try Data("video".utf8).write(to: videoURL)

    let repository = LocalMediaRepository()
    let rootFolder = folder(at: rootURL)
    let destination = MediaTransferDestination(folderID: MediaFolder.ID(url: destinationURL))

    try await repository.transfer(
      MediaTransfer(
        sources: [transferSource(at: pictureURL, kind: .picture)],
        destination: destination,
        operation: .copy
      ),
      in: rootFolder
    )
    #expect(fileManager.fileExists(atPath: pictureURL.path))
    #expect(
      fileManager.fileExists(
        atPath: destinationURL.appending(path: pictureURL.lastPathComponent).path
      ))

    try await repository.transfer(
      MediaTransfer(
        sources: [transferSource(at: videoURL, kind: .video)],
        destination: destination,
        operation: .move
      ),
      in: rootFolder
    )
    let movedVideoURL = destinationURL.appending(path: videoURL.lastPathComponent)
    #expect(!fileManager.fileExists(atPath: videoURL.path))
    #expect(fileManager.fileExists(atPath: movedVideoURL.path))

    try await repository.transfer(
      MediaTransfer(
        sources: [transferSource(at: movedVideoURL, kind: .video)],
        destination: destination,
        operation: .move
      ),
      in: rootFolder
    )
    #expect(fileManager.fileExists(atPath: movedVideoURL.path))
  }

  @Test
  func rejectsNameConflictsWithoutChangingEitherFile() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let sourceURL = rootURL.appending(path: "Source", directoryHint: .isDirectory)
    let destinationURL = rootURL.appending(path: "Destination", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let sourceFileURL = sourceURL.appending(path: "photo.jpg")
    let destinationFileURL = destinationURL.appending(path: "photo.jpg")
    let sourceData = Data("source".utf8)
    let destinationData = Data("destination".utf8)
    try sourceData.write(to: sourceFileURL)
    try destinationData.write(to: destinationFileURL)

    let repository = LocalMediaRepository()
    await #expect(throws: MediaRepositoryError.self) {
      try await repository.transfer(
        MediaTransfer(
          sources: [transferSource(at: sourceFileURL, kind: .picture)],
          destination: MediaTransferDestination(folderID: MediaFolder.ID(url: destinationURL)),
          operation: .move
        ),
        in: folder(at: rootURL)
      )
    }

    #expect(try Data(contentsOf: sourceFileURL) == sourceData)
    #expect(try Data(contentsOf: destinationFileURL) == destinationData)
  }

  private func paths(
    _ items: [MediaItem],
    option: MediaSortOption,
    direction: MediaSortDirection
  ) -> [String] {
    LocalMediaRepository.sortMediaItems(
      items,
      by: MediaSort(option: option, direction: direction)
    ).map(\.relativePath)
  }

  private func item(path: String, dateAdded: Date?, fileSize: Int64?) -> MediaItem {
    MediaItem(
      id: MediaItem.ID(url: URL(fileURLWithPath: "/Library/\(path)")),
      name: path,
      kind: .picture,
      dateAdded: dateAdded,
      fileSize: fileSize,
      modificationDate: nil,
      relativePath: path
    )
  }

  private func folder(at url: URL) -> Folder {
    Folder(id: Folder.ID(), name: url.lastPathComponent, path: url.path, url: url)
  }

  private func transferSource(at url: URL, kind: MediaItem.Kind) -> MediaTransferSource {
    MediaTransferSource(
      item: MediaItem(
        id: MediaItem.ID(url: url),
        name: url.lastPathComponent,
        kind: kind,
        dateAdded: nil,
        fileSize: nil,
        modificationDate: nil,
        relativePath: url.lastPathComponent
      )
    )
  }
}
