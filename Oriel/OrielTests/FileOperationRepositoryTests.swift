import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Oriel

struct FileOperationRepositoryTests {
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
    #expect(imageFrameCount(at: originalURL) == 2)
  }

  private func mediaTarget(at url: URL) -> FileOperationTarget {
    .media(
      MediaItem(
        id: MediaItem.ID(url: url),
        name: url.lastPathComponent,
        kind: .picture,
        dateAdded: nil,
        fileSize: nil,
        modificationDate: nil,
        relativePath: url.lastPathComponent
      )
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
    let height = 4
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
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else {
      return nil
    }

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

  private func imageType(at url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceGetType(source) as String?
  }

  private func imageFrameCount(at url: URL) -> Int? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceGetCount(source)
  }
}
