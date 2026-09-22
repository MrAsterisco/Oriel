import Foundation
import ImageIO
import Nuke
import QuickLookThumbnailing
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

nonisolated protocol MediaRepository: Sendable {
  func snapshot(
    of rootFolder: Folder,
    destination: MediaBrowserDestination,
    sort: MediaSort
  ) async throws -> MediaBrowserSnapshot
  func recentMedia(in rootFolder: Folder) async throws -> [MediaItem]
  func thumbnail(for item: MediaItem) async throws -> MediaThumbnail
  func picture(for item: MediaItem) async throws -> PictureContent
  func transfer(_ transfer: MediaTransfer, in rootFolder: Folder) async throws
  func updates(in folder: Folder) async -> AsyncStream<Void>
}

nonisolated enum MediaRepositoryError: LocalizedError, Sendable {
  case invalidPicture
  case invalidTransferDestination
  case invalidTransferSource(String)
  case nameConflict(String)
  case readOnlyDestination
  case thumbnailUnavailable
  case transferFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidPicture:
      "This file isn’t a supported picture."
    case .invalidTransferDestination:
      "The selected folder isn’t a valid drop destination."
    case .invalidTransferSource(let name):
      "\(name) isn’t a supported picture or video."
    case .nameConflict(let name):
      "A file named \(name) already exists in this folder."
    case .readOnlyDestination:
      "This folder is read-only or unavailable."
    case .thumbnailUnavailable:
      "A thumbnail couldn’t be created for this file."
    case .transferFailed(let message):
      "The transfer couldn’t be completed: \(message)"
    }
  }
}

actor LocalMediaRepository: MediaRepository {
  private static let pictureMaxPixelSize: Float = 4096
  private static let supportedPictureTypeIdentifiers = Set(
    CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
  )
  private static let thumbnailMaxPixelSize: Float = 480

  private let imagePipeline: ImagePipeline
  private var presenters: [UUID: FolderChangePresenter] = [:]

  init(
    imagePipeline: ImagePipeline = .shared
  ) {
    self.imagePipeline = imagePipeline
  }

  func snapshot(
    of rootFolder: Folder,
    destination: MediaBrowserDestination,
    sort: MediaSort
  ) async throws -> MediaBrowserSnapshot {
    return try await Self.performFileIO {
      let fileManager = FileManager()
      let folderTree = try Self.makeFolderTree(
        at: rootFolder.url,
        requiresAccess: true,
        fileManager: fileManager
      )

      let selectedFolder: MediaFolder?
      let mediaItems: [MediaItem]
      switch destination {
      case .recents:
        selectedFolder = nil
        mediaItems = Self.sortMediaItems(
          try Self.makeMediaItemsRecursively(
            in: rootFolder.url,
            relativeTo: rootFolder.url,
            fileManager: fileManager
          ),
          by: .initial
        )
      case .folder(let id):
        let folder = Self.findFolder(id, in: folderTree) ?? folderTree
        selectedFolder = folder
        mediaItems = Self.sortMediaItems(
          try Self.makeMediaItems(
            in: folder.id.url,
            relativeTo: rootFolder.url,
            fileManager: fileManager
          ),
          by: sort
        )
      }

      return MediaBrowserSnapshot(
        folderTree: folderTree,
        selectedFolder: selectedFolder,
        mediaItems: mediaItems
      )
    }
  }

  func recentMedia(in rootFolder: Folder) async throws -> [MediaItem] {
    return try await Self.performFileIO {
      let fileManager = FileManager()
      return Self.sortMediaItems(
        try Self.makeMediaItemsRecursively(
          in: rootFolder.url,
          relativeTo: rootFolder.url,
          fileManager: fileManager
        ),
        by: .initial
      )
    }
  }

  func thumbnail(for item: MediaItem) async throws -> MediaThumbnail {
    if item.kind == .picture {
      return MediaThumbnail(
        image: try await loadImage(for: item, maxPixelSize: Self.thumbnailMaxPixelSize)
      )
    }

    let request = QLThumbnailGenerator.Request(
      fileAt: item.id.url,
      size: CGSize(width: 240, height: 240),
      scale: 2,
      representationTypes: .thumbnail
    )
    let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(
      for: request
    )
    return MediaThumbnail(image: MediaImage(cgImage: representation.cgImage))
  }

  func picture(for item: MediaItem) async throws -> PictureContent {
    guard item.kind == .picture else {
      throw MediaRepositoryError.invalidPicture
    }
    return PictureContent(
      item: item,
      image: try await loadImage(for: item, maxPixelSize: Self.pictureMaxPixelSize),
      pixelSize: try await Self.performFileIO {
        guard
          let source = CGImageSourceCreateWithURL(item.id.url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
          throw MediaRepositoryError.invalidPicture
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
          ? MediaPixelSize(width: height, height: width)
          : MediaPixelSize(width: width, height: height)
      }
    )
  }

  func transfer(_ transfer: MediaTransfer, in rootFolder: Folder) async throws {
    try await Self.performFileIO {
      let fileManager = FileManager()
      let destinationURL = transfer.destination.folderID.url.standardizedFileURL
      guard Self.contains(destinationURL, in: rootFolder.url) else {
        throw MediaRepositoryError.invalidTransferDestination
      }

      let destinationValues = try destinationURL.resourceValues(
        forKeys: [.isDirectoryKey, .isWritableKey]
      )
      guard destinationValues.isDirectory == true else {
        throw MediaRepositoryError.invalidTransferDestination
      }
      guard destinationValues.isWritable == true,
        fileManager.isWritableFile(atPath: destinationURL.path)
      else {
        throw MediaRepositoryError.readOnlyDestination
      }

      let accessedURLs = Set(transfer.sources.map(\.id.url)).filter {
        $0.startAccessingSecurityScopedResource()
      }
      defer {
        for url in accessedURLs {
          url.stopAccessingSecurityScopedResource()
        }
      }

      var destinationURLs = Set<URL>()
      var prepared: [PreparedMediaTransfer] = []
      for source in transfer.sources {
        try Task.checkCancellation()
        let sourceURL = source.id.url.standardizedFileURL
        let values = try sourceURL.resourceValues(
          forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          Self.mediaKind(
            for: values.contentType ?? UTType(filenameExtension: sourceURL.pathExtension)
          ) != nil
        else {
          throw MediaRepositoryError.invalidTransferSource(sourceURL.lastPathComponent)
        }

        if sourceURL.deletingLastPathComponent().standardizedFileURL == destinationURL {
          continue
        }

        let itemDestination = destinationURL.appending(
          path: sourceURL.lastPathComponent,
          directoryHint: .notDirectory
        )
        guard destinationURLs.insert(itemDestination).inserted,
          !fileManager.fileExists(atPath: itemDestination.path)
        else {
          throw MediaRepositoryError.nameConflict(sourceURL.lastPathComponent)
        }
        prepared.append(
          PreparedMediaTransfer(
            sourceURL: sourceURL,
            destinationURL: itemDestination,
            expectedSize: values.fileSize
          )
        )
      }

      var copiedDestinations: [URL] = []
      do {
        for item in prepared {
          try Task.checkCancellation()
          try fileManager.copyItem(at: item.sourceURL, to: item.destinationURL)
          copiedDestinations.append(item.destinationURL)
          let copiedValues = try item.destinationURL.resourceValues(
            forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey]
          )
          guard copiedValues.isRegularFile == true,
            Self.mediaKind(
              for: copiedValues.contentType
                ?? UTType(filenameExtension: item.destinationURL.pathExtension)
            ) != nil,
            item.expectedSize.map({ copiedValues.fileSize == $0 }) ?? true
          else {
            throw MediaRepositoryError.transferFailed(
              "\(item.sourceURL.lastPathComponent) could not be validated after copying."
            )
          }
        }
      } catch {
        for destinationURL in copiedDestinations.reversed() {
          try? fileManager.removeItem(at: destinationURL)
        }
        if error is CancellationError { throw CancellationError() }
        if let error = error as? MediaRepositoryError { throw error }
        throw MediaRepositoryError.transferFailed(error.localizedDescription)
      }

      guard transfer.operation == .move else { return }
      for item in prepared {
        try Task.checkCancellation()
        do {
          try fileManager.removeItem(at: item.sourceURL)
        } catch {
          throw MediaRepositoryError.transferFailed(
            "\(item.sourceURL.lastPathComponent) was copied, but the original could not be removed: \(error.localizedDescription)"
          )
        }
      }
    }
  }

  func updates(in folder: Folder) async -> AsyncStream<Void> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let presenter = FolderChangePresenter(url: folder.url, continuation: continuation)
      presenters[id] = presenter
      NSFileCoordinator.addFilePresenter(presenter)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removePresenter(id: id) }
      }
    }
  }

  private func removePresenter(id: UUID) {
    guard let presenter = presenters.removeValue(forKey: id) else { return }
    NSFileCoordinator.removeFilePresenter(presenter)
  }

  nonisolated private static func performFileIO<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    let task = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  nonisolated private static func makeFolderTree(
    at url: URL,
    requiresAccess: Bool,
    fileManager: FileManager
  ) throws -> MediaFolder {
    try Task.checkCancellation()
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
    guard values.isDirectory == true else {
      throw FolderAccessError.invalidFolder
    }

    let childURLs: [URL]
    do {
      childURLs = try fileManager.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .nameKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    } catch {
      if requiresAccess { throw error }
      childURLs = []
    }

    var children: [MediaFolder] = []
    for childURL in childURLs {
      try Task.checkCancellation()
      guard
        let childValues = try? childURL.resourceValues(
          forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        ), childValues.isDirectory == true, childValues.isPackage != true,
        childValues.isSymbolicLink != true
      else {
        continue
      }

      do {
        children.append(
          try makeFolderTree(
            at: childURL,
            requiresAccess: false,
            fileManager: fileManager
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        continue
      }
    }
    children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    return MediaFolder(
      id: MediaFolder.ID(url: url.standardizedFileURL),
      name: values.name ?? folderName(for: url),
      path: url.path,
      children: children.isEmpty ? nil : children
    )
  }

  nonisolated private static func makeMediaItems(
    in folderURL: URL,
    relativeTo rootURL: URL,
    fileManager: FileManager
  ) throws -> [MediaItem] {
    try Task.checkCancellation()
    let items: [MediaItem] = try fileManager.contentsOfDirectory(
      at: folderURL,
      includingPropertiesForKeys: [
        .addedToDirectoryDateKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .creationDateKey,
        .fileSizeKey,
        .isRegularFileKey,
      ],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )
    .compactMap { url in
      guard
        let values = try? url.resourceValues(
          forKeys: [
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .contentTypeKey,
            .creationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
          ]
        ), let item = makeMediaItem(at: url, values: values, relativeTo: rootURL)
      else {
        return nil
      }
      return item
    }
    try Task.checkCancellation()
    return items
  }

  nonisolated private static func makeMediaItemsRecursively(
    in folderURL: URL,
    relativeTo rootURL: URL,
    fileManager: FileManager
  ) throws -> [MediaItem] {
    try Task.checkCancellation()
    let childURLs = try fileManager.contentsOfDirectory(
      at: folderURL,
      includingPropertiesForKeys: [
        .addedToDirectoryDateKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .creationDateKey,
        .isDirectoryKey,
        .isPackageKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )

    var items: [MediaItem] = []
    for url in childURLs {
      try Task.checkCancellation()
      let values = try url.resourceValues(
        forKeys: [
          .addedToDirectoryDateKey,
          .contentModificationDateKey,
          .contentTypeKey,
          .creationDateKey,
          .isDirectoryKey,
          .isPackageKey,
          .isRegularFileKey,
          .isSymbolicLinkKey,
        ]
      )
      if values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true {
        items += try makeMediaItemsRecursively(
          in: url,
          relativeTo: rootURL,
          fileManager: fileManager
        )
      } else if let item = makeMediaItem(at: url, values: values, relativeTo: rootURL) {
        items.append(item)
      }
    }
    return items
  }

  nonisolated private static func makeMediaItem(
    at url: URL,
    values: URLResourceValues,
    relativeTo rootURL: URL
  ) -> MediaItem? {
    guard values.isRegularFile == true,
      let kind = mediaKind(
        for: values.contentType ?? UTType(filenameExtension: url.pathExtension))
    else {
      return nil
    }

    let rootComponentCount = rootURL.standardizedFileURL.pathComponents.count
    let relativePath = url.standardizedFileURL.pathComponents
      .dropFirst(rootComponentCount)
      .joined(separator: "/")
    let fileSize =
      values.fileSize
      ?? (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    return MediaItem(
      id: MediaItem.ID(url: url.standardizedFileURL),
      name: url.lastPathComponent,
      kind: kind,
      dateAdded: values.addedToDirectoryDate ?? values.creationDate
        ?? values.contentModificationDate,
      fileSize: fileSize.map { Int64($0) },
      modificationDate: values.contentModificationDate,
      relativePath: relativePath
    )
  }

  nonisolated static func sortMediaItems(
    _ items: [MediaItem],
    by sort: MediaSort
  ) -> [MediaItem] {
    items.sorted { first, second in
      let precedes: Bool?
      switch sort.option {
      case .mostRecent:
        precedes = compare(first.dateAdded, second.dateAdded, direction: sort.direction)
      case .name:
        let comparison = first.name.localizedStandardCompare(second.name)
        if comparison == .orderedSame {
          precedes = nil
        } else if sort.direction == .ascending {
          precedes = comparison == .orderedAscending
        } else {
          precedes = comparison == .orderedDescending
        }
      case .size:
        precedes = compare(first.fileSize, second.fileSize, direction: sort.direction)
      }
      return precedes ?? (first.relativePath < second.relativePath)
    }
  }

  nonisolated private static func compare<Value: Comparable>(
    _ first: Value?,
    _ second: Value?,
    direction: MediaSortDirection
  ) -> Bool? {
    switch (first, second) {
    case (let first?, let second?) where first != second:
      return direction == .ascending ? first < second : first > second
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return nil
    }
  }

  nonisolated private static func mediaKind(for contentType: UTType?) -> MediaItem.Kind? {
    guard let contentType else { return nil }
    if contentType.conforms(to: .image),
      supportedPictureTypeIdentifiers.contains(contentType.identifier)
    {
      return .picture
    }
    if contentType.conforms(to: .movie) { return .video }
    return nil
  }

  nonisolated private static func contains(_ url: URL, in rootURL: URL) -> Bool {
    let rootComponents = rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    return components.starts(with: rootComponents)
  }

  nonisolated private static func findFolder(
    _ id: MediaFolder.ID,
    in folder: MediaFolder
  ) -> MediaFolder? {
    if folder.id == id { return folder }
    for child in folder.children ?? [] {
      if let match = findFolder(id, in: child) { return match }
    }
    return nil
  }

  private func loadImage(for item: MediaItem, maxPixelSize: Float) async throws -> MediaImage {
    var request = ImageRequest(url: item.id.url)
    request.imageID = cacheID(for: item)
    request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: maxPixelSize)

    if let image = imagePipeline.cache[request]?.image {
      #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
          throw MediaRepositoryError.thumbnailUnavailable
        }
      #else
        guard let cgImage = image.cgImage else {
          throw MediaRepositoryError.thumbnailUnavailable
        }
      #endif

      return MediaImage(cgImage: cgImage)
    }

    let result = try await Self.performFileIO {
      try Task.checkCancellation()
      guard
        let source = CGImageSourceCreateWithURL(
          item.id.url as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source,
          0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          ] as CFDictionary
        )
      else {
        throw MediaRepositoryError.thumbnailUnavailable
      }
      try Task.checkCancellation()
      return MediaImage(cgImage: image)
    }

    #if os(macOS)
      let image = NSImage(
        cgImage: result.cgImage,
        size: NSSize(width: result.cgImage.width, height: result.cgImage.height)
      )
    #else
      let image = UIImage(cgImage: result.cgImage)
    #endif
    imagePipeline.cache[request] = ImageContainer(image: image)
    return result
  }

  private func cacheID(for item: MediaItem) -> String {
    let version = item.modificationDate?.timeIntervalSinceReferenceDate ?? 0
    return "\(item.id.url.absoluteString)#\(version)"
  }

  nonisolated private static func folderName(for url: URL) -> String {
    url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
  }
}

nonisolated private struct PreparedMediaTransfer: Sendable {
  let sourceURL: URL
  let destinationURL: URL
  let expectedSize: Int?
}

nonisolated private final class FolderChangePresenter: NSObject, NSFilePresenter,
  @unchecked Sendable
{
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  private let continuation: AsyncStream<Void>.Continuation

  init(url: URL, continuation: AsyncStream<Void>.Continuation) {
    presentedItemURL = url
    presentedItemOperationQueue = OperationQueue()
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
    self.continuation = continuation
  }

  func presentedItemDidChange() {
    continuation.yield()
  }

  func presentedSubitemDidAppear(at url: URL) {
    continuation.yield()
  }

  func presentedSubitemDidChange(at url: URL) {
    continuation.yield()
  }

  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
    continuation.yield()
  }

  func presentedSubitemDidDisappear(at url: URL) {
    continuation.yield()
  }
}
