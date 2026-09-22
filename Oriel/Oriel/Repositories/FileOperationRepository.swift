import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

nonisolated protocol FileOperationRepository: Sendable {
  func capabilities(
    for target: FileOperationTarget,
    in rootFolder: Folder
  ) async -> FileOperationCapabilities
  func rename(
    _ target: FileOperationTarget,
    to name: String,
    in rootFolder: Folder
  ) async throws -> URL
  func duplicate(_ target: FileOperationTarget, in rootFolder: Folder) async throws -> URL
  func copy(_ target: FileOperationTarget, in rootFolder: Folder) async throws
  func paste(into folder: MediaFolder, in rootFolder: Folder) async throws
  func move(
    _ target: FileOperationTarget,
    to destinationURL: URL,
    in rootFolder: Folder
  ) async throws -> URL
  func createFolder(named name: String, in folder: MediaFolder, rootFolder: Folder) async throws
  func cropPicture(
    _ item: MediaItem,
    to rect: MediaPixelRect,
    saveAsCopy: Bool,
    in rootFolder: Folder
  ) async throws -> URL
  func moveToTrash(_ target: FileOperationTarget, in rootFolder: Folder) async throws
  func delete(_ target: FileOperationTarget, in rootFolder: Folder) async throws
  func info(for target: FileOperationTarget, in rootFolder: Folder) async throws -> FileItemInfo
  func reveal(_ target: FileOperationTarget, in rootFolder: Folder) async throws

  #if os(macOS)
    func openingApplications(
      for target: FileOperationTarget,
      in rootFolder: Folder
    ) async throws -> [FileOpeningApplication]
    func open(
      _ target: FileOperationTarget,
      with applicationURL: URL,
      in rootFolder: Folder
    ) async throws
  #endif
}

nonisolated enum FileOperationRepositoryError: LocalizedError, Sendable {
  case invalidName
  case invalidTarget
  case nameConflict(String)
  case nothingToPaste
  case readOnlyDestination
  case unsupportedOperation(String)

  var errorDescription: String? {
    switch self {
    case .invalidName:
      "Enter a name that isn’t empty and doesn’t contain a slash."
    case .invalidTarget:
      "This item is no longer available."
    case .nameConflict(let name):
      "An item named \(name) already exists in this folder."
    case .nothingToPaste:
      "The clipboard doesn’t contain a file or folder."
    case .readOnlyDestination:
      "This folder is read-only or unavailable."
    case .unsupportedOperation(let message):
      message
    }
  }
}

actor LocalFileOperationRepository: FileOperationRepository {
  func capabilities(
    for target: FileOperationTarget,
    in rootFolder: Folder
  ) async -> FileOperationCapabilities {
    (try? await Self.performFileIO {
      let parentURL = target.url.deletingLastPathComponent()
      let canModify =
        Self.contains(target.url, in: rootFolder.url)
        && FileManager.default.isWritableFile(atPath: parentURL.path)
      let canModifyContents =
        target.isFolder
        && FileManager.default.isWritableFile(atPath: target.url.path)
      return FileOperationCapabilities(
        canModify: canModify,
        canModifyContents: canModifyContents,
        canMoveToTrash: canModify && Self.supportsTrash
      )
    })
      ?? FileOperationCapabilities(
        canModify: false,
        canModifyContents: false,
        canMoveToTrash: false
      )
  }

  func rename(
    _ target: FileOperationTarget,
    to name: String,
    in rootFolder: Folder
  ) async throws -> URL {
    try await Self.performFileIO {
      let sourceURL = try Self.validatedMutableURL(for: target, in: rootFolder)
      let normalizedName = try Self.validatedName(name)
      let destinationURL: URL
      if target.isFolder || sourceURL.pathExtension.isEmpty {
        destinationURL = sourceURL.deletingLastPathComponent().appending(
          path: normalizedName,
          directoryHint: target.isFolder ? .isDirectory : .notDirectory
        )
      } else {
        destinationURL = sourceURL.deletingLastPathComponent()
          .appending(path: normalizedName, directoryHint: .notDirectory)
          .appendingPathExtension(sourceURL.pathExtension)
      }

      if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
        return sourceURL
      }
      try Self.requireAvailable(destinationURL)
      try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
      return destinationURL
    }
  }

  func duplicate(_ target: FileOperationTarget, in rootFolder: Folder) async throws -> URL {
    try await Self.performFileIO {
      let sourceURL = try Self.validatedMutableURL(for: target, in: rootFolder)
      let destinationURL = Self.uniqueCopyURL(for: target, sourceURL: sourceURL)
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL
    }
  }

  func copy(_ target: FileOperationTarget, in rootFolder: Folder) async throws {
    let url = try await Self.performFileIO {
      try Self.validatedURL(for: target, in: rootFolder)
    }

    #if os(macOS)
      let didWrite = await MainActor.run {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
      }
      guard didWrite else {
        throw FileOperationRepositoryError.unsupportedOperation(
          "The item couldn’t be copied to the clipboard."
        )
      }
    #elseif os(iOS)
      await MainActor.run { UIPasteboard.general.urls = [url] }
    #else
      throw FileOperationRepositoryError.unsupportedOperation(
        "Copy isn’t available on this platform."
      )
    #endif
  }

  func paste(into folder: MediaFolder, in rootFolder: Folder) async throws {
    let sourceURLs: [URL]
    #if os(macOS)
      sourceURLs = await MainActor.run {
        (NSPasteboard.general.readObjects(
          forClasses: [NSURL.self],
          options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
      }
    #elseif os(iOS)
      sourceURLs = await MainActor.run { UIPasteboard.general.urls ?? [] }
    #else
      sourceURLs = []
    #endif

    guard !sourceURLs.isEmpty else { throw FileOperationRepositoryError.nothingToPaste }
    try await Self.performFileIO {
      let destinationURL = try Self.validatedDestination(folder.id.url, in: rootFolder)
      let fileManager = FileManager.default
      let destinations = sourceURLs.map {
        destinationURL.appending(path: $0.lastPathComponent)
      }
      for url in destinations { try Self.requireAvailable(url) }

      var copiedURLs: [URL] = []
      do {
        for (sourceURL, destinationURL) in zip(sourceURLs, destinations) {
          try Task.checkCancellation()
          let shouldStop = sourceURL.startAccessingSecurityScopedResource()
          defer {
            if shouldStop { sourceURL.stopAccessingSecurityScopedResource() }
          }
          try fileManager.copyItem(at: sourceURL, to: destinationURL)
          copiedURLs.append(destinationURL)
        }
      } catch {
        for url in copiedURLs.reversed() { try? fileManager.removeItem(at: url) }
        throw error
      }
    }
  }

  func move(
    _ target: FileOperationTarget,
    to destinationURL: URL,
    in rootFolder: Folder
  ) async throws -> URL {
    return try await Self.performFileIO {
      let sourceURL = try Self.validatedMutableURL(for: target, in: rootFolder)
      let sourceValues = try sourceURL.resourceValues(
        forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey]
      )
      let destinationFolderURL = try Self.validatedDestination(destinationURL, in: nil)
      if sourceURL.deletingLastPathComponent().standardizedFileURL
        == destinationFolderURL.standardizedFileURL
      {
        return sourceURL
      }

      let resultURL = destinationFolderURL.appending(
        path: sourceURL.lastPathComponent,
        directoryHint: target.isFolder ? .isDirectory : .notDirectory
      )
      try Self.requireAvailable(resultURL)

      var didCopy = false
      do {
        try FileManager.default.copyItem(at: sourceURL, to: resultURL)
        didCopy = true
        let resultValues = try resultURL.resourceValues(
          forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        )
        guard
          resultValues.isDirectory == sourceValues.isDirectory,
          resultValues.isRegularFile == sourceValues.isRegularFile,
          sourceValues.isDirectory == true
            || sourceValues.fileSize.map({ resultValues.fileSize == $0 }) ?? true
        else {
          throw FileOperationRepositoryError.unsupportedOperation(
            "The copied item couldn’t be verified."
          )
        }
        try Task.checkCancellation()
        try FileManager.default.removeItem(at: sourceURL)
        return resultURL
      } catch {
        if didCopy, FileManager.default.fileExists(atPath: sourceURL.path) {
          try? FileManager.default.removeItem(at: resultURL)
        }
        throw error
      }
    }
  }

  func createFolder(
    named name: String,
    in folder: MediaFolder,
    rootFolder: Folder
  ) async throws {
    try await Self.performFileIO {
      let parentURL = try Self.validatedDestination(folder.id.url, in: rootFolder)
      let destinationURL = parentURL.appending(
        path: try Self.validatedName(name),
        directoryHint: .isDirectory
      )
      try Self.requireAvailable(destinationURL)
      try FileManager.default.createDirectory(
        at: destinationURL,
        withIntermediateDirectories: false
      )
    }
  }

  func cropPicture(
    _ item: MediaItem,
    to rect: MediaPixelRect,
    saveAsCopy: Bool,
    in rootFolder: Folder
  ) async throws -> URL {
    try await Self.performFileIO {
      let target = FileOperationTarget.media(item)
      let sourceURL = try Self.validatedMutableURL(for: target, in: rootFolder)
      guard
        item.kind == .picture,
        rect.x >= 0,
        rect.y >= 0,
        rect.width > 0,
        rect.height > 0
      else {
        throw FileOperationRepositoryError.invalidTarget
      }

      guard
        let source = CGImageSourceCreateWithURL(
          sourceURL as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let sourceType = CGImageSourceGetType(source)
      else {
        throw FileOperationRepositoryError.unsupportedOperation(
          "This picture couldn’t be read."
        )
      }
      guard CGImageSourceGetCount(source) == 1 else {
        throw FileOperationRepositoryError.unsupportedOperation(
          "Multi-frame pictures can’t be cropped yet."
        )
      }
      guard
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
          as? [CFString: Any],
        let rawWidth = sourceProperties[kCGImagePropertyPixelWidth] as? Int,
        let rawHeight = sourceProperties[kCGImagePropertyPixelHeight] as? Int
      else {
        throw FileOperationRepositoryError.unsupportedOperation(
          "This picture couldn’t be read."
        )
      }

      let sourceTypeIsWritable = Set(
        CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
      ).contains(sourceType as String)
      let destinationType = sourceTypeIsWritable ? sourceType : UTType.png.identifier as CFString
      let outputURL =
        sourceTypeIsWritable
        ? sourceURL
        : sourceURL.deletingPathExtension().appendingPathExtension("png")

      let orientation = (sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
      let sourceWidth = (5...8).contains(orientation) ? rawHeight : rawWidth
      let sourceHeight = (5...8).contains(orientation) ? rawWidth : rawHeight
      guard
        rect.width <= sourceWidth,
        rect.height <= sourceHeight,
        rect.x <= sourceWidth - rect.width,
        rect.y <= sourceHeight - rect.height
      else {
        throw FileOperationRepositoryError.invalidTarget
      }

      let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight),
      ]
      guard
        let image = CGImageSourceCreateThumbnailAtIndex(
          source,
          0,
          thumbnailOptions as CFDictionary
        ),
        let croppedImage = image.cropping(
          to: CGRect(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
          )
        )
      else {
        throw FileOperationRepositoryError.unsupportedOperation(
          "The picture couldn’t be cropped to that area."
        )
      }

      let parentURL = sourceURL.deletingLastPathComponent()
      let temporaryURL = parentURL.appending(
        path: ".oriel-crop-\(UUID().uuidString).\(outputURL.pathExtension)",
        directoryHint: .notDirectory
      )
      defer { try? FileManager.default.removeItem(at: temporaryURL) }

      guard
        let destination = CGImageDestinationCreateWithURL(
          temporaryURL as CFURL,
          destinationType,
          1,
          nil
        )
      else {
        throw FileOperationRepositoryError.unsupportedOperation(
          "The cropped picture couldn’t be saved."
        )
      }

      var properties = sourceProperties
      properties[kCGImagePropertyOrientation] = 1
      properties[kCGImagePropertyPixelWidth] = rect.width
      properties[kCGImagePropertyPixelHeight] = rect.height
      CGImageDestinationAddImage(destination, croppedImage, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw FileOperationRepositoryError.unsupportedOperation(
          "The cropped picture couldn’t be saved."
        )
      }

      if saveAsCopy {
        let resultURL = Self.uniqueCopyURL(for: target, sourceURL: outputURL)
        try FileManager.default.moveItem(at: temporaryURL, to: resultURL)
        return resultURL
      }

      if outputURL.standardizedFileURL == sourceURL.standardizedFileURL {
        _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: temporaryURL)
        return sourceURL
      }

      try Self.requireAvailable(outputURL)
      try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
      do {
        try FileManager.default.removeItem(at: sourceURL)
      } catch {
        try? FileManager.default.removeItem(at: outputURL)
        throw error
      }
      return outputURL
    }
  }

  func moveToTrash(_ target: FileOperationTarget, in rootFolder: Folder) async throws {
    #if os(macOS)
      try await Self.performFileIO {
        let url = try Self.validatedMutableURL(for: target, in: rootFolder)
        _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }
    #else
      throw FileOperationRepositoryError.unsupportedOperation(
        "Recoverable Trash isn’t available here."
      )
    #endif
  }

  func delete(_ target: FileOperationTarget, in rootFolder: Folder) async throws {
    try await Self.performFileIO {
      try FileManager.default.removeItem(
        at: try Self.validatedMutableURL(for: target, in: rootFolder)
      )
    }
  }

  func info(for target: FileOperationTarget, in rootFolder: Folder) async throws -> FileItemInfo {
    let basicInfo = try await Self.performFileIO {
      let url = try Self.validatedURL(for: target, in: rootFolder)
      let values = try url.resourceValues(forKeys: [
        .addedToDirectoryDateKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .creationDateKey,
        .fileSizeKey,
      ])
      let dimensions = Self.imageDimensions(at: url)
      return FileItemInfo(
        id: url,
        name: url.lastPathComponent,
        kind: values.contentType?.localizedDescription ?? (target.isFolder ? "Folder" : "File"),
        fileSize: values.fileSize.map(Int64.init),
        dateAdded: values.addedToDirectoryDate,
        creationDate: values.creationDate,
        modificationDate: values.contentModificationDate,
        pixelWidth: dimensions?.width,
        pixelHeight: dimensions?.height,
        duration: nil,
        location: url.deletingLastPathComponent().path
      )
    }

    guard case .media(let item) = target, item.kind == .video else { return basicInfo }
    let asset = AVURLAsset(url: target.url)
    let duration = try? await asset.load(.duration).seconds
    let track = try? await asset.loadTracks(withMediaType: .video).first
    let size = try? await track?.load(.naturalSize)
    let transform = try? await track?.load(.preferredTransform)
    let transformedSize = size.map {
      CGRect(origin: .zero, size: $0)
        .applying(transform ?? .identity)
        .standardized.size
    }
    return FileItemInfo(
      id: basicInfo.id,
      name: basicInfo.name,
      kind: basicInfo.kind,
      fileSize: basicInfo.fileSize,
      dateAdded: basicInfo.dateAdded,
      creationDate: basicInfo.creationDate,
      modificationDate: basicInfo.modificationDate,
      pixelWidth: transformedSize.map { Int($0.width.rounded()) },
      pixelHeight: transformedSize.map { Int($0.height.rounded()) },
      duration: duration?.isFinite == true ? duration : nil,
      location: basicInfo.location
    )
  }

  func reveal(_ target: FileOperationTarget, in rootFolder: Folder) async throws {
    let url = try await Self.performFileIO {
      try Self.validatedURL(for: target, in: rootFolder)
    }
    #if os(macOS)
      await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    #else
      throw FileOperationRepositoryError.unsupportedOperation(
        "Reveal isn’t available on this platform."
      )
    #endif
  }

  #if os(macOS)
    func openingApplications(
      for target: FileOperationTarget,
      in rootFolder: Folder
    ) async throws -> [FileOpeningApplication] {
      let url = try await Self.performFileIO {
        try Self.validatedURL(for: target, in: rootFolder)
      }
      return await MainActor.run {
        var seen = Set<URL>()
        return NSWorkspace.shared.urlsForApplications(toOpen: url)
          .compactMap { applicationURL in
            let applicationURL = applicationURL.standardizedFileURL
            guard seen.insert(applicationURL).inserted else { return nil }
            return FileOpeningApplication(
              id: applicationURL,
              name: FileManager.default.displayName(atPath: applicationURL.path)
            )
          }
          .sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.path < $1.id.path : order == .orderedAscending
          }
      }
    }

    func open(
      _ target: FileOperationTarget,
      with applicationURL: URL,
      in rootFolder: Folder
    ) async throws {
      let url = try await Self.performFileIO {
        try Self.validatedURL(for: target, in: rootFolder)
      }
      await MainActor.run {
        NSWorkspace.shared.open(
          [url],
          withApplicationAt: applicationURL,
          configuration: NSWorkspace.OpenConfiguration()
        )
      }
    }
  #endif

  nonisolated private static func validatedURL(
    for target: FileOperationTarget,
    in rootFolder: Folder
  ) throws -> URL {
    let url = target.url.standardizedFileURL
    guard contains(url, in: rootFolder.url), FileManager.default.fileExists(atPath: url.path) else {
      throw FileOperationRepositoryError.invalidTarget
    }
    return url
  }

  nonisolated private static func validatedMutableURL(
    for target: FileOperationTarget,
    in rootFolder: Folder
  ) throws -> URL {
    let url = try validatedURL(for: target, in: rootFolder)
    guard url != rootFolder.url.standardizedFileURL else {
      throw FileOperationRepositoryError.invalidTarget
    }
    guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
      throw FileOperationRepositoryError.readOnlyDestination
    }
    return url
  }

  nonisolated private static func validatedDestination(
    _ url: URL,
    in rootFolder: Folder?
  ) throws -> URL {
    let url = url.standardizedFileURL
    if let rootFolder, !contains(url, in: rootFolder.url) {
      throw FileOperationRepositoryError.invalidTarget
    }
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
    guard values.isDirectory == true else { throw FileOperationRepositoryError.invalidTarget }
    guard values.isWritable == true, FileManager.default.isWritableFile(atPath: url.path) else {
      throw FileOperationRepositoryError.readOnlyDestination
    }
    return url
  }

  nonisolated private static func validatedName(_ name: String) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0")
    else {
      throw FileOperationRepositoryError.invalidName
    }
    return name
  }

  nonisolated private static func requireAvailable(_ url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw FileOperationRepositoryError.nameConflict(url.lastPathComponent)
    }
  }

  nonisolated private static func uniqueCopyURL(
    for target: FileOperationTarget,
    sourceURL: URL
  ) -> URL {
    let parentURL = sourceURL.deletingLastPathComponent()
    let extensionName = target.isFolder ? "" : sourceURL.pathExtension
    let baseName: String
    if extensionName.isEmpty {
      baseName = sourceURL.lastPathComponent
    } else {
      baseName = String(sourceURL.lastPathComponent.dropLast(extensionName.count + 1))
    }

    var number: Int?
    while true {
      let suffix = number.map { " copy \($0)" } ?? " copy"
      var candidate = parentURL.appending(
        path: baseName + suffix,
        directoryHint: target.isFolder ? .isDirectory : .notDirectory
      )
      if !extensionName.isEmpty { candidate.appendPathExtension(extensionName) }
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      number = (number ?? 1) + 1
    }
  }

  nonisolated private static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      return nil
    }
    return (width, height)
  }

  nonisolated private static func contains(_ url: URL, in rootURL: URL) -> Bool {
    let rootComponents = rootURL.standardizedFileURL.pathComponents
    let components = url.standardizedFileURL.pathComponents
    return components.count >= rootComponents.count
      && Array(components.prefix(rootComponents.count)) == rootComponents
  }

  nonisolated private static func performFileIO<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try await Task.detached(priority: .userInitiated, operation: operation).value
  }

  nonisolated private static var supportsTrash: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }
}
