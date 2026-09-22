import Foundation

nonisolated protocol RecentsFolderRepository: Sendable {
  func recentFolders() async throws -> [RecentFolder]
  func record(_ folder: Folder, replacing recentFolder: RecentFolder?) async throws
  func clear() async throws
}

#if os(macOS)
  import AppKit

  actor SystemRecentsFolderRepository: RecentsFolderRepository {
    private let folderAccess: any FolderAccessRepository

    init(folderAccess: any FolderAccessRepository) {
      self.folderAccess = folderAccess
    }

    func recentFolders() async throws -> [RecentFolder] {
      let urls = await MainActor.run { NSDocumentController.shared.recentDocumentURLs }
      var deletedURLs = Set<URL>()
      var folders: [RecentFolder] = []

      for url in urls {
        do {
          if let folder = try await folderAccess.recentFolder(matching: url) {
            folders.append(folder)
          } else {
            folders.append(
              RecentFolder(
                id: Folder.ID(),
                name: folderName(for: url),
                path: url.path,
                availability: .unavailable
              )
            )
          }
        } catch FolderAccessError.deleted(let id) {
          deletedURLs.insert(url)
          try await folderAccess.removeAuthorization(id: id)
        }
      }

      if !deletedURLs.isEmpty {
        await rebuild(with: urls.filter { !deletedURLs.contains($0) })
      }
      return folders
    }

    func record(_ folder: Folder, replacing recentFolder: RecentFolder?) async throws {
      if let recentFolder, recentFolder.path != folder.path {
        let survivingURLs = await MainActor.run {
          NSDocumentController.shared.recentDocumentURLs.filter { $0.path != recentFolder.path }
        }
        await rebuild(with: survivingURLs)
      }
      await MainActor.run {
        NSDocumentController.shared.noteNewRecentDocumentURL(folder.url)
      }
    }

    func clear() async throws {
      await MainActor.run {
        NSDocumentController.shared.clearRecentDocuments(nil)
      }
    }

    private func rebuild(with urls: [URL]) async {
      await MainActor.run {
        NSDocumentController.shared.clearRecentDocuments(nil)
        for url in urls.reversed() {
          NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
      }
    }

    private func folderName(for url: URL) -> String {
      url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
  }
#else
  actor LocalRecentsFolderRepository: RecentsFolderRepository {
    private struct Entry: Codable {
      let id: Folder.ID
      var name: String
      var path: String
    }

    private let folderAccess: any FolderAccessRepository
    private let defaults: UserDefaults
    private let storageKey = "recent-folders"
    private var entries: [Entry]

    init(
      folderAccess: any FolderAccessRepository,
      defaults: UserDefaults = .standard
    ) {
      self.folderAccess = folderAccess
      self.defaults = defaults
      entries =
        defaults.data(forKey: storageKey)
        .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func recentFolders() async throws -> [RecentFolder] {
      var resolved: [RecentFolder] = []
      var survivingEntries: [Entry] = []

      for entry in entries {
        do {
          let folder = try await folderAccess.recentFolder(id: entry.id)
          resolved.append(folder)
          survivingEntries.append(Entry(id: folder.id, name: folder.name, path: folder.path))
        } catch FolderAccessError.deleted(let id) {
          try await folderAccess.removeAuthorization(id: id)
        } catch {
          resolved.append(
            RecentFolder(
              id: entry.id,
              name: entry.name,
              path: entry.path,
              availability: .unavailable
            )
          )
          survivingEntries.append(entry)
        }
      }

      entries = survivingEntries
      try save()
      return resolved
    }

    func record(_ folder: Folder, replacing recentFolder: RecentFolder?) async throws {
      entries.removeAll { $0.id == folder.id || $0.id == recentFolder?.id }
      entries.insert(Entry(id: folder.id, name: folder.name, path: folder.path), at: 0)
      try save()
    }

    func clear() async throws {
      entries.removeAll()
      try save()
    }

    private func save() throws {
      defaults.set(try JSONEncoder().encode(entries), forKey: storageKey)
    }
  }
#endif
