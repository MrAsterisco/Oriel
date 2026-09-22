import Foundation
import Observation

@MainActor
protocol WelcomeFeatureModelProtocol: AnyObject, Observable {
  var appVersion: String { get }
  var currentFolder: Folder? { get }
  var errorMessage: String? { get }
  var isFolderPickerPresented: Bool { get }
  var isLoadingRecents: Bool { get }
  var recentFolders: [RecentFolder] { get }

  func clearRecents() async
  func dismissError()
  func handleFolderSelection(_ result: Result<[URL], any Error>) async
  func loadRecents() async
  func openFolderPicker()
  func openRecentFolder(_ recentFolder: RecentFolder) async
  func setFolderPickerPresented(_ isPresented: Bool)
  func stopAccessingCurrentFolder() async
}

@MainActor
@Observable
final class WelcomeFeatureModel: WelcomeFeatureModelProtocol {
  private let folderAccess: any FolderAccessRepository
  private let recents: any RecentsFolderRepository
  private var hasLoadedRecents = false
  private var recentFolderBeingLocated: RecentFolder?

  let appVersion: String
  private(set) var currentFolder: Folder?
  private(set) var errorMessage: String?
  private(set) var isFolderPickerPresented = false
  private(set) var isLoadingRecents = false
  private(set) var recentFolders: [RecentFolder] = []

  init(
    applicationInfo: any ApplicationInfoRepository,
    folderAccess: any FolderAccessRepository,
    recents: any RecentsFolderRepository
  ) {
    self.folderAccess = folderAccess
    self.recents = recents
    appVersion = applicationInfo.version
  }

  func loadRecents() async {
    guard !hasLoadedRecents else { return }
    hasLoadedRecents = true
    await refreshRecents()
  }

  func openFolderPicker() {
    recentFolderBeingLocated = nil
    isFolderPickerPresented = true
  }

  func setFolderPickerPresented(_ isPresented: Bool) {
    isFolderPickerPresented = isPresented
  }

  func handleFolderSelection(_ result: Result<[URL], any Error>) async {
    isFolderPickerPresented = false
    defer { recentFolderBeingLocated = nil }

    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      await openSelectedFolder(url)
    case .failure(let error):
      if !isCancellation(error) {
        errorMessage = error.localizedDescription
      }
    }
  }

  func openRecentFolder(_ recentFolder: RecentFolder) async {
    guard recentFolder.availability == .available else {
      requestRelocation(of: recentFolder)
      return
    }

    do {
      let folder = try await folderAccess.openFolder(id: recentFolder.id)
      await show(folder, replacing: recentFolder)
    } catch FolderAccessError.deleted {
      await refreshRecents()
    } catch {
      requestRelocation(of: recentFolder)
    }
  }

  func clearRecents() async {
    do {
      try await recents.clear()
      recentFolders = []
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func dismissError() {
    errorMessage = nil
  }

  func stopAccessingCurrentFolder() async {
    guard let currentFolder else { return }
    await folderAccess.stopAccessing(currentFolder)
    self.currentFolder = nil
  }

  private func openSelectedFolder(_ url: URL) async {
    do {
      let folder = try await folderAccess.authorize(url, replacing: recentFolderBeingLocated)
      await show(folder, replacing: recentFolderBeingLocated)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func requestRelocation(of recentFolder: RecentFolder) {
    recentFolderBeingLocated = recentFolder
    isFolderPickerPresented = true
  }

  private func show(_ folder: Folder, replacing recentFolder: RecentFolder?) async {
    do {
      try await recents.record(folder, replacing: recentFolder)
    } catch {
      errorMessage = error.localizedDescription
    }

    if let currentFolder, currentFolder.id != folder.id {
      await folderAccess.stopAccessing(currentFolder)
    }
    currentFolder = folder
  }

  private func refreshRecents() async {
    isLoadingRecents = true
    defer { isLoadingRecents = false }

    do {
      recentFolders = try await recents.recentFolders()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func isCancellation(_ error: any Error) -> Bool {
    let error = error as NSError
    return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
  }
}
