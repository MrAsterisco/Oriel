import Foundation

nonisolated protocol FolderAccessRepository: Sendable {
  func authorize(_ url: URL, replacing recentFolder: RecentFolder?) async throws -> Folder
  func authorizeTransient(_ url: URL) async throws -> Folder
  func openFolder(id: Folder.ID) async throws -> Folder
  func openFolder(matching url: URL) async throws -> Folder
  func recentFolder(id: Folder.ID) async throws -> RecentFolder
  func recentFolder(matching url: URL) async throws -> RecentFolder?
  func removeAuthorization(id: Folder.ID) async throws
  func stopAccessing(_ folder: Folder) async
}

nonisolated enum FolderAccessError: LocalizedError, Sendable {
  case deleted(Folder.ID)
  case invalidFolder
  case unavailable

  var errorDescription: String? {
    switch self {
    case .deleted:
      "This folder no longer exists."
    case .invalidFolder:
      "The selected item is not a folder."
    case .unavailable:
      "This folder is unavailable. Locate it again to restore access."
    }
  }
}

nonisolated struct ActiveFolderAccess {
  let url: URL
  let shouldStop: Bool
  private(set) var retainCount = 1

  mutating func retain() {
    retainCount += 1
  }

  mutating func release() -> Bool {
    precondition(retainCount > 0)
    retainCount -= 1
    return retainCount == 0
  }
}

actor BookmarkFolderAccessRepository: FolderAccessRepository {
  private struct Entry: Codable {
    let id: Folder.ID
    var bookmark: Data
    var name: String
    var url: URL
    var volumeURL: URL
  }

  private struct ResolvedEntry {
    let folder: Folder
    let recentFolder: RecentFolder
  }

  private let defaults: UserDefaults
  private let storageKey = "folder-access.bookmarks"
  private var entries: [Entry]
  private var activeAccess: [Folder.ID: [URL: ActiveFolderAccess]] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    entries =
      defaults.data(forKey: storageKey)
      .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
  }

  func authorize(_ url: URL, replacing recentFolder: RecentFolder?) async throws -> Folder {
    let startedAccess = url.startAccessingSecurityScopedResource()
    var didRetainAccess = false
    defer {
      if startedAccess && !didRetainAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey, .volumeURLKey])
    guard values.isDirectory == true else {
      throw FolderAccessError.invalidFolder
    }

    let existingID = try matchingEntryID(for: url)
    let id = existingID ?? recentFolder?.id ?? Folder.ID()
    let bookmark = try url.bookmarkData(
      options: bookmarkCreationOptions,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    let entry = Entry(
      id: id,
      bookmark: bookmark,
      name: values.name ?? folderName(for: url),
      url: url,
      volumeURL: values.volume ?? url.deletingLastPathComponent()
    )

    entries.removeAll { $0.id == id }
    entries.append(entry)
    try save()

    retainAccess(id: id, url: url, startedAccess: startedAccess)
    didRetainAccess = true
    return makeFolder(from: entry, url: url)
  }

  func authorizeTransient(_ url: URL) async throws -> Folder {
    let startedAccess = url.startAccessingSecurityScopedResource()
    var retainedAccess = false
    defer {
      if startedAccess && !retainedAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
    guard values.isDirectory == true else { throw FolderAccessError.invalidFolder }

    let folder = Folder(
      id: Folder.ID(),
      name: values.name ?? folderName(for: url),
      path: url.path,
      url: url
    )
    retainAccess(id: folder.id, url: url, startedAccess: startedAccess)
    retainedAccess = true
    return folder
  }

  func openFolder(id: Folder.ID) async throws -> Folder {
    guard let index = entries.firstIndex(where: { $0.id == id }) else {
      throw FolderAccessError.unavailable
    }

    let url: URL
    do {
      url = try resolveURL(at: index)
    } catch {
      if isConfirmedDeleted(entries[index]) {
        throw FolderAccessError.deleted(id)
      }
      throw FolderAccessError.unavailable
    }

    retainAccess(id: id, url: url)

    do {
      return try updateMetadata(at: index, url: url).folder
    } catch {
      releaseAccess(id: id, url: url)
      if isConfirmedDeleted(entries[index]) {
        throw FolderAccessError.deleted(id)
      }
      throw FolderAccessError.unavailable
    }
  }

  func openFolder(matching url: URL) async throws -> Folder {
    guard let recent = try await recentFolder(matching: url) else {
      throw FolderAccessError.unavailable
    }
    return try await openFolder(id: recent.id)
  }

  func recentFolder(id: Folder.ID) async throws -> RecentFolder {
    guard let index = entries.firstIndex(where: { $0.id == id }) else {
      throw FolderAccessError.unavailable
    }
    return try resolveRecentFolder(at: index).recentFolder
  }

  func recentFolder(matching url: URL) async throws -> RecentFolder? {
    for index in entries.indices {
      do {
        let resolved = try resolveRecentFolder(at: index)
        if resolved.folder.url.standardizedFileURL == url.standardizedFileURL {
          return resolved.recentFolder
        }
      } catch FolderAccessError.deleted(let id) {
        if entries[index].url.standardizedFileURL == url.standardizedFileURL {
          throw FolderAccessError.deleted(id)
        }
      } catch {
        if entries[index].url.standardizedFileURL == url.standardizedFileURL {
          return unavailableRecentFolder(from: entries[index])
        }
      }
    }
    return nil
  }

  func removeAuthorization(id: Folder.ID) async throws {
    stop(activeAccess.removeValue(forKey: id)?.values)
    entries.removeAll { $0.id == id }
    try save()
  }

  func stopAccessing(_ folder: Folder) async {
    releaseAccess(id: folder.id, url: folder.url)
  }

  private func resolveRecentFolder(at index: Int) throws -> ResolvedEntry {
    let entry = entries[index]
    let url: URL
    do {
      url = try resolveURL(at: index)
    } catch {
      if isConfirmedDeleted(entry) {
        throw FolderAccessError.deleted(entry.id)
      }
      return ResolvedEntry(
        folder: makeFolder(from: entry, url: entry.url),
        recentFolder: unavailableRecentFolder(from: entry)
      )
    }

    let alreadyActive = isActive(id: entry.id, url: url)
    let startedAccess = alreadyActive ? false : url.startAccessingSecurityScopedResource()
    defer {
      if startedAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      return try updateMetadata(at: index, url: url)
    } catch {
      if isConfirmedDeleted(entry) {
        throw FolderAccessError.deleted(entry.id)
      }
      return ResolvedEntry(
        folder: makeFolder(from: entry, url: entry.url),
        recentFolder: unavailableRecentFolder(from: entry)
      )
    }
  }

  private func resolveURL(at index: Int) throws -> URL {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: entries[index].bookmark,
      options: bookmarkResolutionOptions,
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )

    if isStale {
      let alreadyActive = isActive(id: entries[index].id, url: url)
      let startedAccess = alreadyActive ? false : url.startAccessingSecurityScopedResource()
      defer {
        if startedAccess {
          url.stopAccessingSecurityScopedResource()
        }
      }
      entries[index].bookmark = try url.bookmarkData(
        options: bookmarkCreationOptions,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      try save()
    }
    return url
  }

  private func updateMetadata(at index: Int, url: URL) throws -> ResolvedEntry {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey, .volumeURLKey])
    guard values.isDirectory == true else {
      throw FolderAccessError.invalidFolder
    }

    entries[index].name = values.name ?? folderName(for: url)
    entries[index].url = url
    entries[index].volumeURL = values.volume ?? entries[index].volumeURL
    try save()

    let folder = makeFolder(from: entries[index], url: url)
    return ResolvedEntry(
      folder: folder,
      recentFolder: RecentFolder(
        id: folder.id,
        name: folder.name,
        path: folder.path,
        availability: .available
      )
    )
  }

  private func matchingEntryID(for url: URL) throws -> Folder.ID? {
    for index in entries.indices {
      guard let resolvedURL = try? resolveURL(at: index) else {
        continue
      }
      if resolvedURL.standardizedFileURL == url.standardizedFileURL {
        return entries[index].id
      }
    }
    return nil
  }

  private func isConfirmedDeleted(_ entry: Entry) -> Bool {
    guard entry.url.standardizedFileURL != entry.volumeURL.standardizedFileURL,
      isReachable(entry.volumeURL),
      isReachable(entry.url.deletingLastPathComponent())
    else {
      return false
    }

    do {
      return try !entry.url.checkResourceIsReachable()
    } catch {
      let cocoaError = error as NSError
      return cocoaError.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code)
    }
  }

  private func isReachable(_ url: URL) -> Bool {
    (try? url.checkResourceIsReachable()) == true
  }

  private func retainAccess(id: Folder.ID, url: URL, startedAccess: Bool? = nil) {
    let key = url.standardizedFileURL
    if var access = activeAccess[id]?[key] {
      access.retain()
      activeAccess[id]?[key] = access
      if startedAccess == true {
        url.stopAccessingSecurityScopedResource()
      }
      return
    }

    activeAccess[id, default: [:]][key] = ActiveFolderAccess(
      url: url,
      shouldStop: startedAccess ?? url.startAccessingSecurityScopedResource()
    )
  }

  private func releaseAccess(id: Folder.ID, url: URL) {
    let key = url.standardizedFileURL
    guard var access = activeAccess[id]?[key] else { return }

    if access.release() {
      stop(access)
      activeAccess[id]?.removeValue(forKey: key)
      if activeAccess[id]?.isEmpty == true {
        activeAccess.removeValue(forKey: id)
      }
    } else {
      activeAccess[id]?[key] = access
    }
  }

  private func isActive(id: Folder.ID, url: URL) -> Bool {
    activeAccess[id]?[url.standardizedFileURL] != nil
  }

  private func stop(_ access: ActiveFolderAccess) {
    if access.shouldStop {
      access.url.stopAccessingSecurityScopedResource()
    }
  }

  private func stop(_ accesses: Dictionary<URL, ActiveFolderAccess>.Values?) {
    for access in accesses ?? [:].values {
      stop(access)
    }
  }

  private func makeFolder(from entry: Entry, url: URL) -> Folder {
    Folder(id: entry.id, name: entry.name, path: url.path, url: url)
  }

  private func unavailableRecentFolder(from entry: Entry) -> RecentFolder {
    RecentFolder(
      id: entry.id,
      name: entry.name,
      path: entry.url.path,
      availability: .unavailable
    )
  }

  private func folderName(for url: URL) -> String {
    url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
  }

  private func save() throws {
    defaults.set(try JSONEncoder().encode(entries), forKey: storageKey)
  }

  private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
    #if os(macOS)
      [.withSecurityScope]
    #else
      []
    #endif
  }

  private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
    #if os(macOS)
      [.withSecurityScope, .withoutUI]
    #else
      [.withoutUI]
    #endif
  }
}
