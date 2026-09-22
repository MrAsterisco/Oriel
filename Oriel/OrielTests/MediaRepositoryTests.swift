import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Oriel

struct MediaRepositoryTests {
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
