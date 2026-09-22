import Foundation

nonisolated enum FileOperationTarget: Identifiable, Hashable, Sendable {
  case media(MediaItem)
  case folder(MediaFolder)

  var id: URL { url.standardizedFileURL }

  var url: URL {
    switch self {
    case .media(let item): item.id.url
    case .folder(let folder): folder.id.url
    }
  }

  var name: String {
    switch self {
    case .media(let item): item.name
    case .folder(let folder): folder.name
    }
  }

  var editableName: String {
    switch self {
    case .media:
      let extensionLength = url.pathExtension.count
      guard extensionLength > 0 else { return name }
      return String(name.dropLast(extensionLength + 1))
    case .folder:
      return name
    }
  }

  var isFolder: Bool {
    if case .folder = self { return true }
    return false
  }
}

nonisolated struct FileOperationCapabilities: Hashable, Sendable {
  let canModify: Bool
  let canModifyContents: Bool
  let canMoveToTrash: Bool
}

#if os(macOS)
  nonisolated struct FileOpeningApplication: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
  }
#endif

nonisolated struct FileItemInfo: Identifiable, Hashable, Sendable {
  let id: URL
  let name: String
  let kind: String
  let fileSize: Int64?
  let dateAdded: Date?
  let creationDate: Date?
  let modificationDate: Date?
  let pixelWidth: Int?
  let pixelHeight: Int?
  let duration: TimeInterval?
  let location: String
}
