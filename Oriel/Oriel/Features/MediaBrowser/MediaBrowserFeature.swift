import CoreGraphics
import Foundation
import Observation

nonisolated enum MediaNavigationDirection: Equatable, Sendable {
  case next
  case previous
}

@MainActor
protocol MediaBrowserFeatureModelProtocol: AnyObject, Observable {
  var alertMessage: String? { get }
  var alertTitle: String { get }
  var errorMessage: String? { get }
  var fileOperationCapabilities: [URL: FileOperationCapabilities] { get }
  var filteredFolderTree: MediaFolder? { get }
  var folderSearchText: String { get }
  var folderTree: MediaFolder? { get }
  var isLoading: Bool { get }
  var isLoadingMedia: Bool { get }
  var isSavingViewerMode: Bool { get }
  var mediaSort: MediaSort { get }
  var mediaItems: [MediaItem] { get }
  var mediaItemsByID: [MediaItem.ID: MediaItem] { get }
  var mediaItemsRevision: Int { get }
  var mediaThumbnails: [MediaItem.ID: MediaThumbnail] { get }
  var openedMedia: OpenedMedia? { get }
  var panOffset: CGSize { get }
  var selectedDestination: MediaBrowserDestination { get }
  var selectedDestinationName: String { get }
  var selectedFolder: MediaFolder? { get }
  var selectedMediaID: MediaItem.ID? { get }
  var viewerMode: MediaViewerMode? { get }
  var zoomScale: CGFloat { get }

  func activateMedia(_ item: MediaItem) async
  func beginCrop()
  func cancelViewerMode()
  func closeMedia()
  func copy(_ target: FileOperationTarget) async
  func createFolder(named name: String, in folder: MediaFolder) async
  func delete(_ target: FileOperationTarget) async
  func discardThumbnail(for item: MediaItem)
  func dismissAlert()
  func dragSource(for item: MediaItem) -> MediaTransferSource
  func duplicate(_ target: FileOperationTarget) async
  func fileInfo(for target: FileOperationTarget) async -> FileItemInfo?
  func loadFileOperationCapabilities(for target: FileOperationTarget) async
  func loadThumbnail(for item: MediaItem) async
  func move(_ target: FileOperationTarget, to destinationURL: URL) async
  func moveToTrash(_ target: FileOperationTarget) async
  func navigate(_ direction: MediaNavigationDirection) async
  func paste(into folder: MediaFolder) async
  func prepareFolderForOpening(_ folder: MediaFolder) async -> Folder.ID?
  func rename(_ target: FileOperationTarget, to name: String) async
  func resetZoom()
  func reveal(_ target: FileOperationTarget) async
  func revealInFolder(_ item: MediaItem) async
  func retry() async
  func run() async
  func saveCrop(asCopy: Bool) async
  func selectDestination(_ destination: MediaBrowserDestination) async
  func selectMedia(_ item: MediaItem?)
  func selectSortOption(_ option: MediaSortOption) async
  func setFolderSearchText(_ text: String)
  func setCropRect(_ rect: MediaNormalizedRect)
  func setViewerTransform(zoomScale: CGFloat, panOffset: CGSize)
  func thumbnail(for item: MediaItem) -> MediaThumbnail?
  func transfer(
    _ sources: [MediaTransferSource],
    to destination: MediaTransferDestination,
    operation: MediaTransferOperation
  ) async
  func zoomIn()
  func zoomOut()

  #if os(macOS)
    var openingApplications: [URL: [FileOpeningApplication]] { get }

    func loadOpeningApplications(for target: FileOperationTarget) async
    func open(_ target: FileOperationTarget, with applicationURL: URL) async
  #endif
}

@MainActor
@Observable
final class MediaBrowserFeatureModel: MediaBrowserFeatureModelProtocol {
  private let fileOperations: any FileOperationRepository
  private let folder: Folder
  private let folderAccess: any FolderAccessRepository
  private let mediaRepository: any MediaRepository
  private let fileChangeRefreshDelay: Duration
  private var isObserving = false
  private var isReadingSnapshot = false
  private var loadedThumbnailItems: [MediaItem.ID: MediaItem] = [:]
  private var thumbnailLoadIDs: [MediaItem.ID: UUID] = [:]
  private var needsRefreshAfterCurrent = false
  private var refreshSequence = 0
  private var refreshTask: Task<Void, Never>?

  private(set) var alertMessage: String?
  private(set) var alertTitle = "Couldn’t Open Picture"
  private(set) var errorMessage: String?
  private(set) var fileOperationCapabilities: [URL: FileOperationCapabilities] = [:]
  private(set) var folderSearchText = ""
  private(set) var folderTree: MediaFolder?
  private(set) var isLoading = true
  private(set) var isLoadingMedia = false
  private(set) var isSavingViewerMode = false
  private(set) var mediaSort = MediaSort.initial
  private(set) var mediaItems: [MediaItem] = []
  private(set) var mediaItemsByID: [MediaItem.ID: MediaItem] = [:]
  private(set) var mediaItemsRevision = 0
  private(set) var mediaThumbnails: [MediaItem.ID: MediaThumbnail] = [:]
  private(set) var openedMedia: OpenedMedia?
  private(set) var panOffset = CGSize.zero
  private(set) var selectedDestination = MediaBrowserDestination.recents
  private(set) var selectedDestinationName = "Recents"
  private(set) var selectedFolder: MediaFolder?
  private(set) var selectedMediaID: MediaItem.ID?
  private(set) var viewerMode: MediaViewerMode?
  private(set) var zoomScale: CGFloat = 1

  var filteredFolderTree: MediaFolder? {
    guard let folderTree else { return nil }
    let searchText = folderSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !searchText.isEmpty else { return folderTree }
    return filteredFolder(folderTree, containing: searchText)
  }

  #if os(macOS)
    private var loadingOpeningApplicationTargets = Set<URL>()
    private(set) var openingApplications: [URL: [FileOpeningApplication]] = [:]
  #endif

  init(
    folder: Folder,
    mediaRepository: any MediaRepository,
    fileOperations: any FileOperationRepository,
    folderAccess: any FolderAccessRepository,
    fileChangeRefreshDelay: Duration = .milliseconds(150)
  ) {
    self.folder = folder
    self.mediaRepository = mediaRepository
    self.fileOperations = fileOperations
    self.folderAccess = folderAccess
    self.fileChangeRefreshDelay = fileChangeRefreshDelay
  }

  func run() async {
    guard !isObserving else { return }
    isObserving = true
    defer {
      isObserving = false
      if Task.isCancelled { cancelRefresh() }
    }

    let updates = await mediaRepository.updates(in: folder)
    guard !Task.isCancelled else { return }
    await refresh(showsLoading: true)
    guard !Task.isCancelled else { return }
    for await _ in updates {
      guard !Task.isCancelled else { return }
      scheduleFileChangeRefresh()
    }
  }

  func retry() async {
    await refresh(showsLoading: true)
  }

  func selectDestination(_ destination: MediaBrowserDestination) async {
    guard destination != selectedDestination else { return }
    selectedDestination = destination
    selectedMediaID = nil
    openedMedia = nil
    viewerMode = nil
    resetZoom()
    await refresh(showsLoading: true)
  }

  func selectSortOption(_ option: MediaSortOption) async {
    if option == mediaSort.option {
      let direction: MediaSortDirection =
        mediaSort.direction == .ascending ? .descending : .ascending
      mediaSort = MediaSort(option: option, direction: direction)
    } else {
      mediaSort = MediaSort(option: option, direction: .ascending)
    }
    await refresh()
  }

  func setFolderSearchText(_ text: String) {
    folderSearchText = text
  }

  func loadThumbnail(for item: MediaItem) async {
    guard loadedThumbnailItems[item.id] != item else { return }
    let loadID = UUID()
    thumbnailLoadIDs[item.id] = loadID
    defer {
      if thumbnailLoadIDs[item.id] == loadID {
        thumbnailLoadIDs.removeValue(forKey: item.id)
      }
    }

    guard
      let thumbnail = try? await mediaRepository.thumbnail(for: item),
      !Task.isCancelled,
      thumbnailLoadIDs[item.id] == loadID,
      mediaItemsByID[item.id] == item
    else {
      return
    }
    mediaThumbnails[item.id] = thumbnail
    loadedThumbnailItems[item.id] = item
  }

  func thumbnail(for item: MediaItem) -> MediaThumbnail? {
    mediaThumbnails[item.id]
  }

  func discardThumbnail(for item: MediaItem) {
    thumbnailLoadIDs.removeValue(forKey: item.id)
    mediaThumbnails.removeValue(forKey: item.id)
    loadedThumbnailItems.removeValue(forKey: item.id)
  }

  func selectMedia(_ item: MediaItem?) {
    guard let item else {
      guard selectedMediaID != nil else { return }
      selectedMediaID = nil
      return
    }
    guard mediaItemsByID[item.id] != nil else { return }
    guard selectedMediaID != item.id else { return }
    selectedMediaID = item.id
  }

  func dragSource(for item: MediaItem) -> MediaTransferSource {
    MediaTransferSource(item: item)
  }

  func loadFileOperationCapabilities(for target: FileOperationTarget) async {
    fileOperationCapabilities[target.id] = await fileOperations.capabilities(
      for: target,
      in: folder
    )
  }

  func rename(_ target: FileOperationTarget, to name: String) async {
    await performMutation(target: target, selectsResult: true) {
      try await fileOperations.rename(target, to: name, in: folder)
    }
  }

  func duplicate(_ target: FileOperationTarget) async {
    await performMutation {
      try await fileOperations.duplicate(target, in: folder)
    }
  }

  func copy(_ target: FileOperationTarget) async {
    await performCommand(title: "Couldn’t Copy Item") {
      try await fileOperations.copy(target, in: folder)
    }
  }

  func paste(into destination: MediaFolder) async {
    await performMutation {
      try await fileOperations.paste(into: destination, in: folder)
      return nil
    }
  }

  func prepareFolderForOpening(_ mediaFolder: MediaFolder) async -> Folder.ID? {
    if mediaFolder.id.url.standardizedFileURL == folder.url.standardizedFileURL {
      return folder.id
    }

    do {
      let authorizedFolder = try await folderAccess.authorize(
        mediaFolder.id.url,
        replacing: nil
      )
      await folderAccess.stopAccessing(authorizedFolder)
      return authorizedFolder.id
    } catch {
      presentFileOperationError(title: "Couldn’t Open Folder", error: error)
      return nil
    }
  }

  func move(_ target: FileOperationTarget, to destinationURL: URL) async {
    do {
      let destination = try await folderAccess.authorizeTransient(destinationURL)
      defer { Task { await folderAccess.stopAccessing(destination) } }
      await performMutation(target: target, selectsResult: true) {
        try await fileOperations.move(target, to: destination.url, in: folder)
      }
    } catch {
      presentFileOperationError(title: "Couldn’t Move Item", error: error)
    }
  }

  func createFolder(named name: String, in destination: MediaFolder) async {
    await performMutation {
      try await fileOperations.createFolder(named: name, in: destination, rootFolder: folder)
      return nil
    }
  }

  func moveToTrash(_ target: FileOperationTarget) async {
    await performMutation(target: target) {
      try await fileOperations.moveToTrash(target, in: folder)
      return nil
    }
  }

  func delete(_ target: FileOperationTarget) async {
    await performMutation(target: target) {
      try await fileOperations.delete(target, in: folder)
      return nil
    }
  }

  func fileInfo(for target: FileOperationTarget) async -> FileItemInfo? {
    do {
      return try await fileOperations.info(for: target, in: folder)
    } catch {
      presentFileOperationError(title: "Couldn’t Get Info", error: error)
      return nil
    }
  }

  func reveal(_ target: FileOperationTarget) async {
    await performCommand(title: "Couldn’t Reveal Item") {
      try await fileOperations.reveal(target, in: folder)
    }
  }

  func revealInFolder(_ item: MediaItem) async {
    guard selectedDestination == .recents else { return }
    let destination = MediaBrowserDestination.folder(
      MediaFolder.ID(url: item.id.url.deletingLastPathComponent().standardizedFileURL)
    )
    await selectDestination(destination)
    guard selectedDestination == destination else { return }
    selectMedia(item)
  }

  #if os(macOS)
    func loadOpeningApplications(for target: FileOperationTarget) async {
      guard openingApplications[target.id] == nil,
        loadingOpeningApplicationTargets.insert(target.id).inserted
      else {
        return
      }
      defer { loadingOpeningApplicationTargets.remove(target.id) }
      openingApplications[target.id] =
        (try? await fileOperations.openingApplications(for: target, in: folder)) ?? []
    }

    func open(_ target: FileOperationTarget, with applicationURL: URL) async {
      await performCommand(title: "Couldn’t Open Item") {
        try await fileOperations.open(target, with: applicationURL, in: folder)
      }
    }
  #endif

  func activateMedia(_ item: MediaItem) async {
    guard !isSavingViewerMode else { return }
    viewerMode = nil
    selectMedia(item)
    switch item.kind {
    case .video:
      openedMedia = .video(item)
      resetZoom()
    case .picture:
      isLoadingMedia = true
      defer { isLoadingMedia = false }

      do {
        openedMedia = .picture(try await mediaRepository.picture(for: item))
        resetZoom()
      } catch {
        alertTitle = "Couldn’t Open Picture"
        alertMessage = error.localizedDescription
      }
    }
  }

  func transfer(
    _ sources: [MediaTransferSource],
    to destination: MediaTransferDestination,
    operation: MediaTransferOperation
  ) async {
    guard !sources.isEmpty else { return }
    do {
      try await mediaRepository.transfer(
        MediaTransfer(sources: sources, destination: destination, operation: operation),
        in: folder
      )
      await refresh(after: fileChangeRefreshDelay)
    } catch is CancellationError {
      await refresh(after: fileChangeRefreshDelay)
      return
    } catch {
      await refresh(after: fileChangeRefreshDelay)
      alertTitle = "Couldn’t Transfer Media"
      alertMessage = error.localizedDescription
    }
  }

  func navigate(_ direction: MediaNavigationDirection) async {
    guard
      !isLoadingMedia,
      viewerMode == nil,
      mediaItems.count > 1,
      let currentID = openedMedia?.item.id,
      let currentIndex = mediaItems.firstIndex(where: { $0.id == currentID })
    else {
      return
    }

    let offset = direction == .next ? 1 : -1
    let nextIndex = (currentIndex + offset + mediaItems.count) % mediaItems.count
    await activateMedia(mediaItems[nextIndex])
  }

  func setViewerTransform(zoomScale: CGFloat, panOffset: CGSize) {
    setZoom(zoomScale)
    self.panOffset = self.zoomScale == 1 ? .zero : panOffset
  }

  func zoomIn() {
    setZoom(zoomScale * 1.25)
  }

  func zoomOut() {
    setZoom(zoomScale / 1.25)
  }

  func resetZoom() {
    zoomScale = 1
    panOffset = .zero
  }

  func beginCrop() {
    guard
      !isSavingViewerMode,
      viewerMode == nil,
      case .picture(let picture) = openedMedia,
      fileOperationCapabilities[picture.item.id.url.standardizedFileURL]?.canModify == true
    else {
      return
    }
    resetZoom()
    viewerMode = .crop(
      PictureCrop(originalSize: picture.pixelSize, normalizedRect: .full)
    )
  }

  func setCropRect(_ rect: MediaNormalizedRect) {
    guard
      rect.x.isFinite,
      rect.y.isFinite,
      rect.width.isFinite,
      rect.height.isFinite,
      case .crop(let crop) = viewerMode,
      crop.originalSize.width > 0,
      crop.originalSize.height > 0
    else {
      return
    }

    let minimumWidth = 1 / Double(crop.originalSize.width)
    let minimumHeight = 1 / Double(crop.originalSize.height)
    let width = min(max(rect.width, minimumWidth), 1)
    let height = min(max(rect.height, minimumHeight), 1)
    viewerMode = .crop(
      PictureCrop(
        originalSize: crop.originalSize,
        normalizedRect: MediaNormalizedRect(
          x: min(max(rect.x, 0), 1 - width),
          y: min(max(rect.y, 0), 1 - height),
          width: width,
          height: height
        )
      )
    )
  }

  func cancelViewerMode() {
    guard !isSavingViewerMode else { return }
    viewerMode = nil
  }

  func saveCrop(asCopy: Bool) async {
    guard
      !isSavingViewerMode,
      case .crop(let crop) = viewerMode,
      case .picture(let picture) = openedMedia
    else {
      return
    }

    isSavingViewerMode = true
    defer { isSavingViewerMode = false }
    do {
      let resultURL = try await fileOperations.cropPicture(
        picture.item,
        to: crop.pixelRect,
        saveAsCopy: asCopy,
        in: folder
      )
      viewerMode = nil
      await refresh(after: fileChangeRefreshDelay)
      isSavingViewerMode = false
      if let item = mediaItemsByID[MediaItem.ID(url: resultURL.standardizedFileURL)] {
        await activateMedia(item)
      }
    } catch {
      presentFileOperationError(title: "Couldn’t Crop Picture", error: error)
    }
  }

  func closeMedia() {
    guard !isSavingViewerMode else { return }
    openedMedia = nil
    viewerMode = nil
    resetZoom()
  }

  func dismissAlert() {
    alertMessage = nil
  }

  private func refresh(after delay: Duration = .zero, showsLoading: Bool = false) async {
    let task = scheduleRefresh(after: delay, showsLoading: showsLoading)
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func scheduleFileChangeRefresh() {
    if refreshTask != nil {
      if isReadingSnapshot { needsRefreshAfterCurrent = true }
      return
    }
    scheduleRefresh(after: fileChangeRefreshDelay)
  }

  @discardableResult
  private func scheduleRefresh(
    after delay: Duration = .zero,
    showsLoading: Bool = false
  ) -> Task<Void, Never> {
    refreshSequence &+= 1
    let sequence = refreshSequence
    needsRefreshAfterCurrent = false
    refreshTask?.cancel()
    isReadingSnapshot = false
    if showsLoading { isLoading = true }

    let destination = selectedDestination
    let sort = mediaSort
    let repository = mediaRepository
    let rootFolder = folder
    let task = Task { [weak self] in
      do {
        if delay > .zero {
          try await Task.sleep(for: delay)
        }
        guard let self, self.refreshSequence == sequence else { return }
        self.isReadingSnapshot = true
        let snapshot = try await repository.snapshot(
          of: rootFolder,
          destination: destination,
          sort: sort
        )
        try Task.checkCancellation()
        guard self.refreshSequence == sequence else { return }
        self.apply(snapshot, sequence: sequence)
      } catch is CancellationError {
        guard let self, self.refreshSequence == sequence else { return }
        self.finishRefresh(sequence)
      } catch {
        guard let self, self.refreshSequence == sequence else { return }
        self.applyRefreshError(error, sequence: sequence)
      }
    }
    refreshTask = task
    return task
  }

  private func apply(_ snapshot: MediaBrowserSnapshot, sequence: Int) {
    folderTree = snapshot.folderTree
    selectedFolder = snapshot.selectedFolder
    if let selectedFolder = snapshot.selectedFolder {
      selectedDestination = .folder(selectedFolder.id)
      selectedDestinationName = selectedFolder.name
    } else {
      selectedDestination = .recents
      selectedDestinationName = "Recents"
    }
    mediaItems = snapshot.mediaItems
    mediaItemsByID = snapshot.mediaItemsByID
    mediaItemsRevision &+= 1
    fileOperationCapabilities.removeAll()
    errorMessage = nil

    if let selectedMediaID, snapshot.mediaItemsByID[selectedMediaID] == nil {
      self.selectedMediaID = nil
    }
    mediaThumbnails = mediaThumbnails.filter { snapshot.mediaItemsByID[$0.key] != nil }
    loadedThumbnailItems = loadedThumbnailItems.filter { snapshot.mediaItemsByID[$0.key] != nil }
    thumbnailLoadIDs = thumbnailLoadIDs.filter { snapshot.mediaItemsByID[$0.key] != nil }
    if let openedMedia, snapshot.mediaItemsByID[openedMedia.item.id] == nil {
      self.openedMedia = nil
      viewerMode = nil
      resetZoom()
    }
    finishRefresh(sequence)
  }

  private func applyRefreshError(_ error: any Error, sequence: Int) {
    mediaItems = []
    mediaItemsByID = [:]
    mediaItemsRevision &+= 1
    fileOperationCapabilities.removeAll()
    selectedFolder = nil
    selectedMediaID = nil
    errorMessage = error.localizedDescription
    openedMedia = nil
    viewerMode = nil
    resetZoom()
    finishRefresh(sequence)
  }

  private func finishRefresh(_ sequence: Int) {
    guard refreshSequence == sequence else { return }
    refreshTask = nil
    isReadingSnapshot = false
    isLoading = false
    if needsRefreshAfterCurrent {
      needsRefreshAfterCurrent = false
      scheduleFileChangeRefresh()
    }
  }

  private func cancelRefresh() {
    refreshSequence &+= 1
    refreshTask?.cancel()
    refreshTask = nil
    isReadingSnapshot = false
    needsRefreshAfterCurrent = false
    isLoading = false
  }

  private func setZoom(_ scale: CGFloat) {
    zoomScale = min(max(scale, 1), 8)
    if zoomScale == 1 {
      panOffset = .zero
    }
  }

  private func filteredFolder(
    _ folder: MediaFolder,
    containing searchText: String
  ) -> MediaFolder? {
    let filteredChildren =
      folder.children?.compactMap { filteredFolder($0, containing: searchText) } ?? []
    guard
      folder.name.localizedCaseInsensitiveContains(searchText) || !filteredChildren.isEmpty
    else {
      return nil
    }
    return MediaFolder(
      id: folder.id,
      name: folder.name,
      path: folder.path,
      children: filteredChildren.isEmpty ? nil : filteredChildren
    )
  }

  private func performMutation(
    target: FileOperationTarget? = nil,
    selectsResult: Bool = false,
    _ operation: () async throws -> URL?
  ) async {
    do {
      let resultURL = try await operation()
      if case .folder(let affectedFolder) = target,
        selectedDestination == .folder(affectedFolder.id)
      {
        selectedDestination =
          resultURL.map {
            .folder(MediaFolder.ID(url: $0.standardizedFileURL))
          } ?? .recents
      }

      await refresh(after: fileChangeRefreshDelay)
      if selectsResult, let resultURL,
        let item = mediaItems.first(where: {
          $0.id.url.standardizedFileURL == resultURL.standardizedFileURL
        })
      {
        selectedMediaID = item.id
      }
    } catch {
      presentFileOperationError(title: "Couldn’t Modify Item", error: error)
    }
  }

  private func performCommand(
    title: String,
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
    } catch {
      presentFileOperationError(title: title, error: error)
    }
  }

  private func presentFileOperationError(title: String, error: any Error) {
    alertTitle = title
    alertMessage = error.localizedDescription
  }
}
