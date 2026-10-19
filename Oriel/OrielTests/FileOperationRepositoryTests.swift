import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Oriel

struct FileOperationRepositoryTests {
  #if os(macOS)
    @Test
    func mergePreservesAllContentsAndPreflightsConflicts() async throws {
      let manager = FileManager.default
      let rootURL = manager.temporaryDirectory.appending(path: UUID().uuidString)
      try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
      defer { try? manager.removeItem(at: rootURL) }
      let root = Folder(id: .init(), name: "Root", path: rootURL.path, url: rootURL)
      let folders = ["Zulu", "Alpha", "Middle"].map { name in
        let url = rootURL.appending(path: name)
        return MediaFolder(id: .init(url: url), name: name, path: url.path, children: nil)
      }
      for folder in folders {
        try manager.createDirectory(at: folder.id.url, withIntermediateDirectories: false)
      }
      let repository = LocalFileOperationRepository()
      try Data("first".utf8).write(to: folders[0].id.url.appending(path: "same.txt"))
      try Data("second".utf8).write(to: folders[2].id.url.appending(path: "same.txt"))
      await #expect(throws: FileOperationRepositoryError.self) {
        try await repository.merge(folders, in: root)
      }
      #expect(try manager.contentsOfDirectory(atPath: folders[1].path).isEmpty)
      #expect(manager.fileExists(atPath: folders[0].id.url.appending(path: "same.txt").path))
      let second = folders[2].id.url.appending(path: "same.txt")
      try manager.moveItem(at: second, to: folders[2].id.url.appending(path: "other.txt"))
      try Data("hidden".utf8).write(to: folders[0].id.url.appending(path: ".hidden"))
      let nested = folders[0].id.url.appending(path: "Nested")
      try manager.createDirectory(at: nested, withIntermediateDirectories: false)
      try Data("nested".utf8).write(to: nested.appending(path: "notes.txt"))
      try await repository.merge(folders, in: root)
      let destination = folders[1].id.url
      #expect(try Data(contentsOf: destination.appending(path: "same.txt")) == Data("first".utf8))
      #expect(try Data(contentsOf: destination.appending(path: "other.txt")) == Data("second".utf8))
      #expect(try Data(contentsOf: destination.appending(path: ".hidden")) == Data("hidden".utf8))
      #expect(
        try Data(contentsOf: destination.appending(path: "Nested/notes.txt")) == Data("nested".utf8)
      )
      #expect(!manager.fileExists(atPath: folders[0].path))
      #expect(!manager.fileExists(atPath: folders[2].path))
    }

    @Test
    func cancelledMergeKeepsSourceContents() async throws {
      let manager = FileManager.default
      let url = manager.temporaryDirectory.appending(path: UUID().uuidString)
      let urls = ["Alpha", "Beta"].map { url.appending(path: $0, directoryHint: .isDirectory) }
      for child in urls {
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
      }
      defer { try? manager.removeItem(at: url) }
      let original = urls[1].appending(path: "notes.txt")
      try Data("original".utf8).write(to: original)
      let folders = urls.map {
        MediaFolder(id: .init(url: $0), name: $0.lastPathComponent, path: $0.path, children: nil)
      }
      let root = Folder(id: .init(), name: "Root", path: url.path, url: url)
      let repository = LocalFileOperationRepository()
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await repository.merge(folders, in: root)
      }
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(try Data(contentsOf: original) == Data("original".utf8))
      #expect(try manager.contentsOfDirectory(atPath: urls[0].path).isEmpty)
    }

    @Test
    func mergeRejectsRootAndOverlappingFolders() async throws {
      let manager = FileManager.default
      let url = manager.temporaryDirectory.appending(path: UUID().uuidString)
      let nested = url.appending(path: "A/Nested")
      try manager.createDirectory(at: nested, withIntermediateDirectories: true)
      defer { try? manager.removeItem(at: url) }
      let root = Folder(id: .init(), name: "Root", path: url.path, url: url)
      let folders = [url, url.appending(path: "A"), nested].map {
        MediaFolder(id: .init(url: $0), name: $0.lastPathComponent, path: $0.path, children: nil)
      }
      let repository = LocalFileOperationRepository()
      for selection in [Array(folders.prefix(2)), Array(folders.suffix(2))] {
        await #expect(throws: FileOperationRepositoryError.self) {
          try await repository.merge(selection, in: root)
        }
      }
      #expect(manager.fileExists(atPath: nested.path))
    }
  #endif

  @Test
  func renamesDuplicatesMovesAndDeletesWithoutOverwriting() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    let destinationURL = rootURL.appending(path: "Destination", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let originalURL = rootURL.appending(path: "photo.jpg")
    try Data("picture".utf8).write(to: originalURL)

    let rootFolder = Folder(
      id: Folder.ID(),
      name: rootURL.lastPathComponent,
      path: rootURL.path,
      url: rootURL
    )
    let destinationFolder = MediaFolder(
      id: MediaFolder.ID(url: destinationURL),
      name: "Destination",
      path: destinationURL.path,
      children: nil
    )
    let repository = LocalFileOperationRepository()

    let renamedURL = try await repository.rename(
      mediaTarget(at: originalURL),
      to: "renamed",
      in: rootFolder
    )
    #expect(renamedURL.lastPathComponent == "renamed.jpg")
    #expect(fileManager.fileExists(atPath: renamedURL.path))

    let duplicateURL = try await repository.duplicate(
      mediaTarget(at: renamedURL),
      in: rootFolder
    )
    #expect(duplicateURL.lastPathComponent == "renamed copy.jpg")

    let movedURL = try await repository.move(
      mediaTarget(at: duplicateURL),
      to: destinationURL,
      in: rootFolder
    )
    #expect(!fileManager.fileExists(atPath: duplicateURL.path))
    #expect(fileManager.fileExists(atPath: movedURL.path))

    try Data("existing".utf8).write(
      to: destinationURL.appending(path: renamedURL.lastPathComponent)
    )
    await #expect(throws: FileOperationRepositoryError.self) {
      try await repository.move(
        mediaTarget(at: renamedURL),
        to: destinationURL,
        in: rootFolder
      )
    }
    #expect(fileManager.fileExists(atPath: renamedURL.path))
    #expect(fileManager.fileExists(atPath: movedURL.path))

    let info = try await repository.info(for: mediaTarget(at: renamedURL), in: rootFolder)
    #expect(info.name == "renamed.jpg")
    #expect(info.fileSize == 7)

    try await repository.createFolder(
      named: "New Folder",
      in: destinationFolder,
      rootFolder: rootFolder
    )
    #expect(
      fileManager.fileExists(
        atPath: destinationURL.appending(path: "New Folder").path
      )
    )

    try await repository.delete(mediaTarget(at: renamedURL), in: rootFolder)
    #expect(!fileManager.fileExists(atPath: renamedURL.path))
  }

  @Test
  func rejectsInvalidNamesAndRootFolderMutation() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let rootFolder = Folder(
      id: Folder.ID(),
      name: rootURL.lastPathComponent,
      path: rootURL.path,
      url: rootURL
    )
    let rootTarget = FileOperationTarget.folder(
      MediaFolder(
        id: MediaFolder.ID(url: rootURL),
        name: rootURL.lastPathComponent,
        path: rootURL.path,
        children: nil
      )
    )
    let repository = LocalFileOperationRepository()

    await #expect(throws: FileOperationRepositoryError.self) {
      try await repository.rename(rootTarget, to: "Renamed", in: rootFolder)
    }

    let photoURL = rootURL.appending(path: "photo.jpg")
    try Data().write(to: photoURL)
    await #expect(throws: FileOperationRepositoryError.self) {
      try await repository.rename(mediaTarget(at: photoURL), to: "bad/name", in: rootFolder)
    }
    #expect(fileManager.fileExists(atPath: photoURL.path))
  }

  @Test
  func cropsPicturesInPlaceOrAsAUniqueCopy() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let originalURL = rootURL.appending(path: "photo.png")
    try writePNG(at: originalURL, width: 8, height: 6)
    let rootFolder = Folder(
      id: Folder.ID(),
      name: rootURL.lastPathComponent,
      path: rootURL.path,
      url: rootURL
    )
    let item = MediaItem(
      id: MediaItem.ID(url: originalURL),
      name: originalURL.lastPathComponent,
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: originalURL.lastPathComponent
    )
    let repository = LocalFileOperationRepository()

    let copyURL = try await repository.cropPicture(
      item,
      to: MediaPixelRect(x: 2, y: 1, width: 4, height: 3),
      saveAsCopy: true,
      in: rootFolder
    )

    #expect(copyURL.lastPathComponent == "photo copy.png")
    #expect(imageSize(at: originalURL) == MediaPixelSize(width: 8, height: 6))
    #expect(imageSize(at: copyURL) == MediaPixelSize(width: 4, height: 3))

    let savedURL = try await repository.cropPicture(
      item,
      to: MediaPixelRect(x: 1, y: 2, width: 2, height: 2),
      saveAsCopy: false,
      in: rootFolder
    )

    #expect(savedURL == originalURL)
    #expect(imageSize(at: originalURL) == MediaPixelSize(width: 2, height: 2))
    #expect(imageSize(at: copyURL) == MediaPixelSize(width: 4, height: 3))
  }

  @Test
  func cropCoordinatesUseTheViewerTopLeftOrigin() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let originalURL = rootURL.appending(path: "split.png")
    try writeSplitPNG(at: originalURL)
    let rootFolder = Folder(
      id: Folder.ID(),
      name: rootURL.lastPathComponent,
      path: rootURL.path,
      url: rootURL
    )
    let item = MediaItem(
      id: MediaItem.ID(url: originalURL),
      name: originalURL.lastPathComponent,
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: originalURL.lastPathComponent
    )

    let croppedURL = try await LocalFileOperationRepository().cropPicture(
      item,
      to: MediaPixelRect(x: 0, y: 0, width: 4, height: 2),
      saveAsCopy: true,
      in: rootFolder
    )

    let color = try #require(averageColor(at: croppedURL))
    #expect(color.red > 240)
    #expect(color.green < 15)
    #expect(color.blue < 15)
  }

  @Test
  func cropsDecodeOnlyPicturesAsPNG() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let originalURL = rootURL.appending(path: "photo.webp")
    let webP = try #require(
      Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBIAAAAvA8AAAA8Q87//8x8O5iGi/zE=")
    )
    try webP.write(to: originalURL)
    let rootFolder = Folder(
      id: Folder.ID(),
      name: rootURL.lastPathComponent,
      path: rootURL.path,
      url: rootURL
    )
    let item = MediaItem(
      id: MediaItem.ID(url: originalURL),
      name: originalURL.lastPathComponent,
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: originalURL.lastPathComponent
    )
    let repository = LocalFileOperationRepository()

    let copyURL = try await repository.cropPicture(
      item,
      to: MediaPixelRect(x: 0, y: 0, width: 2, height: 2),
      saveAsCopy: true,
      in: rootFolder
    )
    #expect(copyURL.lastPathComponent == "photo copy.png")
    #expect(imageType(at: copyURL) == UTType.png.identifier)
    #expect(fileManager.fileExists(atPath: originalURL.path))

    let savedURL = try await repository.cropPicture(
      item,
      to: MediaPixelRect(x: 0, y: 0, width: 2, height: 2),
      saveAsCopy: false,
      in: rootFolder
    )
    #expect(savedURL.lastPathComponent == "photo.png")
    #expect(imageType(at: savedURL) == UTType.png.identifier)
    #expect(!fileManager.fileExists(atPath: originalURL.path))
  }

  @Test
  func rejectsMultiFramePicturesWithoutChangingThem() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let originalURL = rootURL.appending(path: "animation.gif")
    try writeGIF(at: originalURL, frameCount: 2)
    let rootFolder = Folder(
      id: Folder.ID(),
      name: rootURL.lastPathComponent,
      path: rootURL.path,
      url: rootURL
    )
    let item = MediaItem(
      id: MediaItem.ID(url: originalURL),
      name: originalURL.lastPathComponent,
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: originalURL.lastPathComponent
    )

    await #expect(throws: FileOperationRepositoryError.self) {
      try await LocalFileOperationRepository().cropPicture(
        item,
        to: MediaPixelRect(x: 0, y: 0, width: 1, height: 1),
        saveAsCopy: false,
        in: rootFolder
      )
    }
    await #expect(throws: FileOperationRepositoryError.self) {
      try await LocalFileOperationRepository().rotatePictureClockwise(item, in: rootFolder)
    }
    #expect(imageFrameCount(at: originalURL) == 2)
  }

  @Test
  func rotatesPictureClockwiseInPlace() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let url = rootURL.appending(path: "split.png")
    try writeSplitPNG(at: url)
    let folder = Folder(
      id: Folder.ID(),
      name: rootURL.lastPathComponent,
      path: rootURL.path,
      url: rootURL
    )
    let repository = LocalFileOperationRepository()
    let item = mediaItem(at: url)

    let rotatedURL = try await repository.rotatePictureClockwise(
      item,
      in: folder
    )
    #expect(rotatedURL == url)
    #expect(imageSize(at: url) == MediaPixelSize(width: 4, height: 6))
    #expect(imageOrientation(at: url) == 6)
    let image = try #require(orientedImage(at: url))
    #expect(
      MediaPixelSize(width: image.width, height: image.height)
        == MediaPixelSize(width: 6, height: 4)
    )

    let left = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 3, height: 4)))
    let right = try #require(image.cropping(to: CGRect(x: 3, y: 0, width: 3, height: 4)))
    let leftColor = try #require(averageColor(of: left))
    let rightColor = try #require(averageColor(of: right))
    #expect(leftColor.blue > 240 && leftColor.red < 15)
    #expect(rightColor.red > 240 && rightColor.blue < 15)

    _ = try await repository.rotatePictureClockwise(item, in: folder)
    #expect(imageOrientation(at: url) == 3)
    let twiceRotated = try #require(orientedImage(at: url))
    #expect(
      MediaPixelSize(width: twiceRotated.width, height: twiceRotated.height)
        == MediaPixelSize(width: 4, height: 6)
    )
  }

  @Test
  func rotatesJPEGWithoutReencodingPixels() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let pngURL = rootURL.appending(path: "split.png")
    let jpegURL = rootURL.appending(path: "split.jpg")
    try writeSplitPNG(at: pngURL)
    let source = try #require(CGImageSourceCreateWithURL(pngURL as CFURL, nil))
    let destination = try #require(
      CGImageDestinationCreateWithURL(jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    #expect(CGImageDestinationFinalize(destination))

    let folder = Folder(id: Folder.ID(), name: "Pictures", path: rootURL.path, url: rootURL)
    _ = try await LocalFileOperationRepository().rotatePictureClockwise(
      mediaItem(at: jpegURL),
      in: folder
    )

    #expect(imageType(at: jpegURL) == UTType.jpeg.identifier)
    #expect(imageSize(at: jpegURL) == MediaPixelSize(width: 4, height: 6))
    #expect(imageOrientation(at: jpegURL) == 6)
    let image = try #require(orientedImage(at: jpegURL))
    #expect(
      MediaPixelSize(width: image.width, height: image.height)
        == MediaPixelSize(width: 6, height: 4)
    )
  }

  private func mediaTarget(at url: URL) -> FileOperationTarget {
    .media(mediaItem(at: url))
  }

  private func mediaItem(at url: URL) -> MediaItem {
    MediaItem(
      id: MediaItem.ID(url: url),
      name: url.lastPathComponent,
      kind: .picture,
      dateAdded: nil,
      fileSize: nil,
      modificationDate: nil,
      relativePath: url.lastPathComponent
    )
  }

  private func writePNG(at url: URL, width: Int, height: Int) throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    let image = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  private func writeSplitPNG(at url: URL) throws {
    let width = 4
    let height = 6
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        pixels[offset] = y < height / 2 ? 255 : 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = y < height / 2 ? 0 : 255
      }
    }

    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  private func writeGIF(at url: URL, frameCount: Int) throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.gif.identifier as CFString,
        frameCount,
        nil
      )
    )
    for frame in 0..<frameCount {
      context.setFillColor(
        frame.isMultiple(of: 2)
          ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
          : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
      CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    }
    #expect(CGImageDestinationFinalize(destination))
  }

  private func averageColor(at url: URL) -> (red: UInt8, green: UInt8, blue: UInt8)? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return nil
    }
    return averageColor(of: image)
  }

  private func averageColor(of image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8)? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

    var pixel = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (pixel[0], pixel[1], pixel[2])
  }

  private func imageSize(at url: URL) -> MediaPixelSize? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      return nil
    }
    return MediaPixelSize(width: width, height: height)
  }

  private func orientedImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 100,
      ] as CFDictionary
    )
  }

  private func imageType(at url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceGetType(source) as String?
  }

  private func imageOrientation(at url: URL) -> Int? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return nil
    }
    return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
  }

  private func imageFrameCount(at url: URL) -> Int? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceGetCount(source)
  }
}
