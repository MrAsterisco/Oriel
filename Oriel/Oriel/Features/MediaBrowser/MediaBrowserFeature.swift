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
  var duplicateGroupCount: Int { get }
  var isScanningDuplicates: Bool { get }
  var showsFolderDuplicates: Bool { get }
  var isShowingDuplicates: Bool { get }
  var isScanningPeople: Bool { get }
  var people: [PersonGroup] { get }
  var faceThumbnails: [FaceThumbnailSource.ID: MediaThumbnail] { get }
  func loadFaceThumbnail(_ source: FaceThumbnailSource) async
  func discardFaceThumbnail(_ source: FaceThumbnailSource)
  var peopleErrorMessage: String? { get }
  var personSearchFaces: [DetectedFace] { get }
  var personSearchFaceIndex: Int? { get }
  var isSearchingPerson: Bool { get }
  var personSearchErrorMessage: String? { get }
  func searchForPerson(using url: URL) async
  func personImageImportFailed(_ error: any Error)
  func selectPersonSearchFace(at index: Int)
  var isCleaningDuplicates: Bool { get }
  var preferredDuplicateIDs: Set<MediaItem.ID> { get }
  func keepBestCopy(in section: MediaSection) async
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
  var mediaSections: [MediaSection] { get }
  var mediaThumbnails: [MediaItem.ID: MediaThumbnail] { get }
  var openedMedia: OpenedMedia? { get }
  var panOffset: CGSize { get }
  var sidebarSelection: Set<MediaBrowserDestination> { get }
  var isShowingMultipleFolders: Bool { get }
  var canMergeSelectedFolders: Bool { get }
  func selectSidebarDestinations(_ destinations: Set<MediaBrowserDestination>) async
  func mergeSelectedFolders() async
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
  func rotatePictureClockwise() async
  func run() async
  func saveCrop(asCopy: Bool) async
  func selectDestination(_ destination: MediaBrowserDestination) async
  func selectMedia(_ item: MediaItem?)
  func selectSortOption(_ option: MediaSortOption) async
  func setFolderSearchText(_ text: String)
  func setShowsFolderDuplicates(_ isEnabled: Bool) async
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
  private let peopleRepository: any PeopleRepository
  private var isMergingFolders = false
  private let fileChangeRefreshDelay: Duration
  private var isObserving = false
  private var isReadingSnapshot = false
  private var loadedThumbnailItems: [MediaItem.ID: MediaItem] = [:]
  private var thumbnailLoadIDs: [MediaItem.ID: UUID] = [:]
  private var needsRefreshAfterCurrent = false
  private var refreshSequence = 0
  private var refreshTask: Task<Void, Never>?
  private var duplicateScanTask: Task<Void, Never>?
  private var duplicateScanID: UUID?
  private var duplicateScanResult: Result<MediaBrowserSnapshot, any Error>?
  private var needsDuplicateScan = false
  private(set) var duplicateGroupCount = 0
  private(set) var isScanningDuplicates = false
  private(set) var showsFolderDuplicates = false
  private(set) var isCleaningDuplicates = false
  private var isMutatingDuplicateFiles = false
  private(set) var preferredDuplicateIDs: Set<MediaItem.ID> = []
  private var duplicateRankingTask: Task<Void, Never>?
  private var rankedSections: [MediaSection] = []
  private var duplicateQualities: [MediaItem: DuplicateImageQuality] = [:]
  private var peopleScanTask: Task<Void, Never>?
  private var peopleScanID: UUID?
  private var needsPeopleScan = false
  private(set) var isScanningPeople = false
  private(set) var people: [PersonGroup] = []
  private(set) var faceThumbnails: [FaceThumbnailSource.ID: MediaThumbnail] = [:]
  private var faceThumbnailLoadIDs: [FaceThumbnailSource.ID: UUID] = [:]
  private(set) var peopleErrorMessage: String?
  private var personSearchTask: Task<Void, Never>?
  private var personSearchID: UUID?
  private var personSearchItems: [MediaItem] = []
  private(set) var personSearchFaces: [DetectedFace] = []
  private(set) var personSearchFaceIndex: Int?
  private(set) var isSearchingPerson = false
  private(set) var personSearchErrorMessage: String?

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
  private(set) var mediaSections: [MediaSection] = []
  private(set) var mediaThumbnails: [MediaItem.ID: MediaThumbnail] = [:]
  private(set) var openedMedia: OpenedMedia?
  private(set) var panOffset = CGSize.zero
  private(set) var selectedDestination = MediaBrowserDestination.recents
  private(set) var selectedDestinationName = "Recents"
  private(set) var selectedFolder: MediaFolder?
  private(set) var selectedMediaID: MediaItem.ID?
  private(set) var viewerMode: MediaViewerMode?
  private(set) var zoomScale: CGFloat = 1

  var isShowingDuplicates: Bool {
    selectedDestination == .duplicates || showsFolderDuplicates
  }

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
    peopleRepository: any PeopleRepository,
    fileOperations: any FileOperationRepository,
    folderAccess: any FolderAccessRepository,
    fileChangeRefreshDelay: Duration = .milliseconds(150)
  ) {
    self.folder = folder
    self.mediaRepository = mediaRepository
    self.peopleRepository = peopleRepository
    self.fileOperations = fileOperations
    self.folderAccess = folderAccess
    self.fileChangeRefreshDelay = fileChangeRefreshDelay
  }

  func run() async {
    guard !isObserving else { return }
    isObserving = true
    defer {
      isObserving = false
      if Task.isCancelled {
        cancelRefresh()
        duplicateRankingTask?.cancel()
        duplicateScanTask?.cancel()
        duplicateScanTask = nil
        duplicateScanID = nil
        isScanningDuplicates = false
        peopleScanTask?.cancel()
        peopleScanTask = nil
        peopleScanID = nil
        isScanningPeople = false
        cancelPersonSearch()
      }
    }

    let updates = await mediaRepository.updates(in: folder)
    guard !Task.isCancelled else { return }
    startDuplicateScan(invalidate: true)
    startPeopleScan(invalidate: true)
    await refresh(showsLoading: true)
    guard !Task.isCancelled else { return }
    for await _ in updates {
      guard !Task.isCancelled else { return }
      scheduleFileChangeRefresh()
    }
  }

  func retry() async {
    await refresh(showsLoading: true, rescanDuplicates: true)
  }

  var sidebarSelection: Set<MediaBrowserDestination> {
    if case .folders(let ids) = selectedDestination { return Set(ids.map { .folder($0) }) }
    if case .person = selectedDestination { return [.people] }
    if selectedDestination == .personSearch { return [.people] }
    return [selectedDestination]
  }

  private var selectedFolders: [MediaFolder] {
    guard case .folders(let ids) = selectedDestination, let folderTree else { return [] }
    func collect(_ folder: MediaFolder) -> [MediaFolder] {
      (ids.contains(folder.id) ? [folder] : []) + (folder.children ?? []).flatMap(collect)
    }
    return collect(folderTree).sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
    }
  }

  var isShowingMultipleFolders: Bool {
    if case .folders = selectedDestination { return true }
    return false
  }

  var canMergeSelectedFolders: Bool {
    let folders = selectedFolders
    guard !isMergingFolders, folders.count > 1 else { return false }
    return folders.allSatisfy { candidate in
      guard candidate.id != folderTree?.id,
        let capabilities = fileOperationCapabilities[candidate.id.url.standardizedFileURL],
        capabilities.canModifyContents, capabilities.canMoveToTrash
      else { return false }
      return !folders.contains { other in
        other.id != candidate.id
          && candidate.id.url.standardizedFileURL.pathComponents
            .starts(with: other.id.url.standardizedFileURL.pathComponents)
      }
    }
  }

  func selectSidebarDestinations(_ destinations: Set<MediaBrowserDestination>) async {
    guard !destinations.isEmpty else { return }
    let added = destinations.subtracting(sidebarSelection)
    let addedFolder = added.contains { if case .folder = $0 { true } else { false } }
    let aggregates: [MediaBrowserDestination] = [.recents, .duplicates, .people]
    if !addedFolder, let aggregate = aggregates.first(where: { added.contains($0) }) {
      await selectDestination(aggregate)
      return
    }
    let ids = Set(
      destinations.compactMap { destination -> MediaFolder.ID? in
        if case .folder(let id) = destination { return id }
        return nil
      })
    if ids.count > 1 {
      await selectDestination(.folders(ids))
    } else if let id = ids.first {
      await selectDestination(.folder(id))
    }
  }

  func mergeSelectedFolders() async {
    guard canMergeSelectedFolders, let first = selectedFolders.first else { return }
    let folders = selectedFolders
    isMergingFolders = true
    defer { isMergingFolders = false }
    do {
      try await fileOperations.merge(folders, in: folder)
      await selectDestination(.folder(first.id))
      await refresh(rescanDuplicates: true)
    } catch {
      await refresh(rescanDuplicates: true)
      presentFileOperationError(title: "Couldn’t Merge Folders", error: error)
    }
  }

  func selectDestination(_ destination: MediaBrowserDestination) async {
    guard destination != selectedDestination else { return }
    faceThumbnailLoadIDs.removeAll()
    faceThumbnails.removeAll()
    if destination != .personSearch { cancelPersonSearch() }
    selectedDestination = destination
    switch destination {
    case .folder: break
    default: showsFolderDuplicates = false
    }
    duplicateRankingTask?.cancel()
    rankedSections = []
    preferredDuplicateIDs = []
    selectedMediaID = nil
    openedMedia = nil
    viewerMode = nil
    resetZoom()
    await refresh(showsLoading: true)
  }

  func searchForPerson(using url: URL) async {
    cancelPersonSearch()
    personSearchFaces = []
    personSearchFaceIndex = nil
    personSearchItems = []
    personSearchErrorMessage = nil
    selectedMediaID = nil
    closeMedia()
    let searchID = UUID()
    personSearchID = searchID
    isSearchingPerson = true
    await selectDestination(.personSearch)
    guard selectedDestination == .personSearch, personSearchID == searchID, !Task.isCancelled else {
      return
    }
    applyPersonSearchResults()
    let repository = peopleRepository
    personSearchTask = Task { [weak self] in
      do {
        let faces = try await repository.referenceFaces(at: url)
        try Task.checkCancellation()
        guard let self, self.personSearchID == searchID else { return }
        self.personSearchFaces = faces
        self.isSearchingPerson = false
        self.personSearchTask = nil
        if faces.count == 1 { self.selectPersonSearchFace(at: 0) }
      } catch {
        guard let self, self.personSearchID == searchID, !Task.isCancelled else { return }
        self.personSearchErrorMessage = error.localizedDescription
        self.isSearchingPerson = false
        self.personSearchTask = nil
      }
    }
  }

  func personImageImportFailed(_ error: any Error) {
    guard (error as? CocoaError)?.code != .userCancelled else { return }
    alertTitle = "Couldn’t Open Reference Image"
    alertMessage = error.localizedDescription
  }

  func selectPersonSearchFace(at index: Int) {
    guard selectedDestination == .personSearch, personSearchFaces.indices.contains(index) else {
      return
    }
    personSearchFaceIndex = index
    personSearchItems = []
    selectedMediaID = nil
    closeMedia()
    applyPersonSearchResults()
    startPersonSearch()
  }

  private func cancelPersonSearch() {
    personSearchTask?.cancel()
    personSearchTask = nil
    personSearchID = nil
    isSearchingPerson = false
  }

  private func startPersonSearch(after delay: Duration = .zero) {
    guard selectedDestination == .personSearch, let index = personSearchFaceIndex else { return }
    cancelPersonSearch()
    let searchID = UUID()
    personSearchID = searchID
    isSearchingPerson = true
    personSearchErrorMessage = nil
    let repository = peopleRepository
    let root = folder
    let face = personSearchFaces[index]
    let retainsResults = !personSearchItems.isEmpty
    personSearchTask = Task { [weak self] in
      do {
        if delay > .zero { try await Task.sleep(for: delay) }
        var latest: [MediaItem] = []
        for try await items in await repository.pictures(matching: face, in: root) {
          try Task.checkCancellation()
          guard let self, self.personSearchID == searchID else { return }
          latest = items
          if !retainsResults {
            self.personSearchItems = items
            self.applyPersonSearchResults()
          }
        }
        try Task.checkCancellation()
        guard let self, self.personSearchID == searchID else { return }
        self.personSearchItems = latest
        self.isSearchingPerson = false
        self.personSearchTask = nil
        self.applyPersonSearchResults()
      } catch {
        guard let self, self.personSearchID == searchID, !Task.isCancelled else { return }
        self.personSearchErrorMessage = error.localizedDescription
        self.isSearchingPerson = false
        self.personSearchTask = nil
      }
    }
  }

  private func applyPersonSearchResults() {
    guard selectedDestination == .personSearch, refreshTask == nil, let folderTree else { return }
    apply(
      MediaBrowserSnapshot(
        folderTree: folderTree, selectedFolder: nil, mediaItems: personSearchItems),
      sequence: refreshSequence)
  }

  func setShowsFolderDuplicates(_ isEnabled: Bool) async {
    guard case .folder = selectedDestination, showsFolderDuplicates != isEnabled else { return }
    showsFolderDuplicates = isEnabled
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
    await refresh(rescanDuplicates: true)
  }

  func setFolderSearchText(_ text: String) {
    folderSearchText = text
  }

  func loadFaceThumbnail(_ source: FaceThumbnailSource) async {
    guard faceThumbnails[source.id] == nil else { return }
    let loadID = UUID()
    faceThumbnailLoadIDs[source.id] = loadID
    defer {
      if faceThumbnailLoadIDs[source.id] == loadID { faceThumbnailLoadIDs[source.id] = nil }
    }
    guard let thumbnail = try? await peopleRepository.thumbnail(for: source),
      !Task.isCancelled, faceThumbnailLoadIDs[source.id] == loadID
    else { return }
    faceThumbnails[source.id] = thumbnail
  }

  func discardFaceThumbnail(_ source: FaceThumbnailSource) {
    faceThumbnailLoadIDs[source.id] = nil
    faceThumbnails[source.id] = nil
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
    let capabilities = await fileOperations.capabilities(
      for: target,
      in: folder
    )
    guard !Task.isCancelled else { return }
    fileOperationCapabilities[target.id] = capabilities
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

  func keepBestCopy(in section: MediaSection) async {
    guard !isCleaningDuplicates,
      isShowingDuplicates,
      let current = mediaSections.first(where: { $0.id == section.id }), current.items.count > 1
    else { return }
    isCleaningDuplicates = true
    defer { isCleaningDuplicates = false }
    do {
      for item in current.items { try await validateDuplicateItem(item) }
      let ranked = try await rankDuplicateItems(current.items)
      let kept = ranked[0]
      let removals = Array(ranked.dropFirst())
      for item in removals {
        let capability = await fileOperations.capabilities(for: .media(item), in: folder)
        guard capability.canModify else { throw FileOperationRepositoryError.readOnlyDestination }
        guard capability.canMoveToTrash else {
          throw FileOperationRepositoryError.unsupportedOperation(
            "Trash isn’t available for these pictures. No copies were removed.")
        }
      }
      await executeDuplicateCleanup(DuplicateCleanupPlan(keptItem: kept, removals: removals))
    } catch {
      presentFileOperationError(title: "Couldn’t Remove Duplicates", error: error)
    }
  }

  private func rankDuplicateItems(_ items: [MediaItem], useCache: Bool = false) async throws
    -> [MediaItem]
  {
    var ranked: [(item: MediaItem, quality: DuplicateImageQuality)] = []
    for item in items {
      try Task.checkCancellation()
      let quality: DuplicateImageQuality
      if useCache, let cached = duplicateQualities[item] {
        quality = cached
      } else {
        quality = try await fileOperations.imageQuality(for: item, in: folder)
        duplicateQualities[item] = quality
      }
      ranked.append((item, quality))
    }
    return ranked.sorted { first, second in
      let a = first.quality
      let b = second.quality
      if a.pixelCount != b.pixelCount { return a.pixelCount > b.pixelCount }
      if a.bitDepth != b.bitDepth { return a.bitDepth > b.bitDepth }
      if a.isLossless != b.isLossless { return a.isLossless }
      if a.fileSize != b.fileSize { return a.fileSize > b.fileSize }
      return first.item.relativePath < second.item.relativePath
    }.map(\.item)
  }

  private func updatePreferredDuplicates() {
    let sections = isShowingDuplicates ? mediaSections : []
    guard sections != rankedSections else { return }
    duplicateRankingTask?.cancel()
    let unchangedIDs = Set(
      sections.filter { rankedSections.contains($0) }.flatMap(\.items).map(\.id))
    preferredDuplicateIDs.formIntersection(unchangedIDs)
    rankedSections = sections
    let items = Set(sections.flatMap(\.items))
    duplicateQualities = duplicateQualities.filter { items.contains($0.key) }
    duplicateRankingTask = Task { [weak self] in
      guard let self else { return }
      for section in sections {
        guard !Task.isCancelled else { return }
        guard let best = try? await self.rankDuplicateItems(section.items, useCache: true).first,
          !Task.isCancelled, self.rankedSections == sections
        else { continue }
        self.preferredDuplicateIDs.insert(best.id)
      }
    }
  }

  private func validateDuplicateItem(_ item: MediaItem) async throws {
    let info = try await fileOperations.info(for: .media(item), in: folder)
    guard info.modificationDate == item.modificationDate, info.fileSize == item.fileSize else {
      throw FileOperationRepositoryError.unsupportedOperation(
        "The pictures changed. Wait for the duplicate scan to refresh and try again.")
    }
  }

  private func executeDuplicateCleanup(_ plan: DuplicateCleanupPlan) async {
    // An in-flight scan may still contain the files we are about to trash.
    duplicateScanTask?.cancel()
    duplicateScanTask = nil
    duplicateScanID = nil
    isScanningDuplicates = false
    isMutatingDuplicateFiles = true
    defer {
      isMutatingDuplicateFiles = false
      startDuplicateScan(invalidate: true, after: fileChangeRefreshDelay)
      startPeopleScan(invalidate: true, after: fileChangeRefreshDelay)
      scheduleRefresh()
    }
    do {
      for item in [plan.keptItem] + plan.removals { try await validateDuplicateItem(item) }
      for item in plan.removals {
        try Task.checkCancellation()
        try await validateDuplicateItem(plan.keptItem)
        try await validateDuplicateItem(item)
        try await fileOperations.moveToTrash(.media(item), in: folder)
        removeTrashedDuplicateFromResults(item.id)
      }
    } catch {
      presentFileOperationError(title: "Couldn’t Remove Duplicates", error: error)
    }
  }

  private func removeTrashedDuplicateFromResults(_ id: MediaItem.ID) {
    guard case .success(let snapshot) = duplicateScanResult else { return }
    let sections = snapshot.sections.compactMap { section -> MediaSection? in
      let remaining = section.items.filter { $0.id != id }
      guard remaining.count > 1 else { return nil }
      return MediaSection(id: section.id, title: section.title, items: remaining)
    }
    let updated = MediaBrowserSnapshot(
      folderTree: snapshot.folderTree, selectedFolder: nil,
      mediaItems: [], sections: sections)
    duplicateScanResult = .success(updated)
    duplicateGroupCount = sections.count
    if isShowingDuplicates { applyDuplicateProgress(updated) }
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
    guard selectedFolder == nil else { return }
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
      await refresh(after: fileChangeRefreshDelay, rescanDuplicates: true)
    } catch is CancellationError {
      await refresh(after: fileChangeRefreshDelay, rescanDuplicates: true)
      return
    } catch {
      await refresh(after: fileChangeRefreshDelay, rescanDuplicates: true)
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
      await refresh(after: fileChangeRefreshDelay, rescanDuplicates: true)
      isSavingViewerMode = false
      if let item = mediaItemsByID[MediaItem.ID(url: resultURL.standardizedFileURL)] {
        await activateMedia(item)
      }
    } catch {
      presentFileOperationError(title: "Couldn’t Crop Picture", error: error)
    }
  }

  func rotatePictureClockwise() async {
    guard
      !isSavingViewerMode,
      viewerMode == nil,
      case .picture(let picture) = openedMedia,
      fileOperationCapabilities[picture.item.id.url.standardizedFileURL]?.canModify == true
    else {
      return
    }

    isSavingViewerMode = true
    defer { isSavingViewerMode = false }
    do {
      let resultURL = try await fileOperations.rotatePictureClockwise(picture.item, in: folder)
      await refresh(after: fileChangeRefreshDelay, rescanDuplicates: true)
      isSavingViewerMode = false
      if let item = mediaItemsByID[MediaItem.ID(url: resultURL.standardizedFileURL)] {
        await activateMedia(item)
        await loadFileOperationCapabilities(for: .media(item))
      }
    } catch {
      presentFileOperationError(title: "Couldn’t Rotate Picture", error: error)
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

  private func mergingDuplicateProgress(_ snapshot: MediaBrowserSnapshot) -> MediaBrowserSnapshot {
    guard case .success(let previous) = duplicateScanResult else { return snapshot }
    var sections = previous.sections
    for incoming in snapshot.sections {
      let incomingIDs = Set(incoming.items.map(\.id))
      let matchingIndices = sections.indices.filter { index in
        sections[index].items.contains { incomingIDs.contains($0.id) }
      }
      guard let firstIndex = matchingIndices.first else {
        sections.append(incoming)
        continue
      }
      // Keep not-yet-revisited members until the completed scan provides an authoritative result.
      let incomingByID = Dictionary(uniqueKeysWithValues: incoming.items.map { ($0.id, $0) })
      let retained = matchingIndices.flatMap { sections[$0].items }.map {
        incomingByID[$0.id] ?? $0
      }
      let retainedIDs = Set(retained.map(\.id))
      let items = retained + incoming.items.filter { !retainedIDs.contains($0.id) }
      sections[firstIndex] = MediaSection(
        id: sections[firstIndex].id, title: incoming.title, items: items)
      for index in matchingIndices.dropFirst().reversed() { sections.remove(at: index) }
    }
    return MediaBrowserSnapshot(
      folderTree: snapshot.folderTree, selectedFolder: nil,
      mediaItems: [], sections: sections)
  }

  private func startDuplicateScan(invalidate: Bool = false, after delay: Duration = .zero) {
    guard !isMutatingDuplicateFiles else { return }
    if duplicateScanTask != nil {
      if invalidate { needsDuplicateScan = true }
      return
    }
    guard invalidate || duplicateScanResult == nil else { return }
    let scanID = UUID()
    duplicateScanID = scanID
    isScanningDuplicates = true
    let repository = mediaRepository
    let rootFolder = folder
    duplicateScanTask = Task { [weak self] in
      do {
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let self else { return }
        repeat {
          self.needsDuplicateScan = false
          let result: Result<MediaBrowserSnapshot, any Error>
          do {
            var latest: MediaBrowserSnapshot?
            for try await snapshot in await repository.duplicateSnapshots(
              in: rootFolder, sort: self.mediaSort)
            {
              try Task.checkCancellation()
              guard self.duplicateScanID == scanID else { return }
              latest = snapshot
              // A queued follow-up scan must not silence this scan's incremental results.
              // Do not erase existing results or badges with an empty partial scan.
              if !snapshot.mediaItems.isEmpty || self.duplicateScanResult == nil {
                let progress = self.mergingDuplicateProgress(snapshot)
                self.duplicateScanResult = .success(progress)
                self.duplicateGroupCount = max(self.duplicateGroupCount, progress.sections.count)
                if self.isShowingDuplicates {
                  self.applyDuplicateProgress(progress)
                }
              }
            }
            guard let latest else { throw CancellationError() }
            result = .success(latest)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            result = .failure(error)
          }
          try Task.checkCancellation()
          guard self.duplicateScanID == scanID else { return }
          // Changes during a scan require a fresh result before clearing the badge.
          if !self.needsDuplicateScan {
            self.duplicateScanResult = result
            if case .success(let snapshot) = result {
              self.duplicateGroupCount = snapshot.sections.count
            }
          }
        } while self.needsDuplicateScan
        self.duplicateScanTask = nil
        self.isScanningDuplicates = false
        if self.isShowingDuplicates && !self.isReadingSnapshot {
          self.scheduleRefresh()
        }
      } catch {
        guard let self, self.duplicateScanID == scanID else { return }
        self.duplicateScanTask = nil
        self.isScanningDuplicates = false
      }
    }
  }

  private func startPeopleScan(invalidate: Bool = false, after delay: Duration = .zero) {
    if peopleScanTask != nil {
      if invalidate { needsPeopleScan = true }
      return
    }
    guard invalidate || peopleScanID == nil else { return }
    let scanID = UUID()
    peopleScanID = scanID
    isScanningPeople = true
    peopleErrorMessage = nil
    let repository = peopleRepository
    let root = folder
    peopleScanTask = Task { [weak self] in
      do {
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let self else { return }
        repeat {
          self.needsPeopleScan = false
          self.peopleErrorMessage = nil
          var latest: [PersonGroup] = []
          do {
            for try await groups in await repository.people(in: root) {
              try Task.checkCancellation()
              guard self.peopleScanID == scanID else { return }
              latest = groups
              // Keep the previous scan's albums until the replacement scan is complete.
              for group in groups {
                if case .person(let id) = self.selectedDestination,
                  group.mergedGroupIDs.contains(id)
                {
                  self.selectedDestination = .person(group.id)
                }
                self.people.removeAll { group.mergedGroupIDs.contains($0.id) }
                if let index = self.people.firstIndex(where: { $0.id == group.id }) {
                  let previous = self.people[index]
                  let ids = Set(group.items.map(\.id))
                  self.people[index] = PersonGroup(
                    id: group.id, name: group.name,
                    thumbnail: group.thumbnail,
                    items: group.items + previous.items.filter { !ids.contains($0.id) },
                    mergedGroupIDs: group.mergedGroupIDs)
                } else {
                  self.people.append(group)
                }
              }
              self.applyPeopleResults()
            }
            try Task.checkCancellation()
            guard self.peopleScanID == scanID else { return }
            if !self.needsPeopleScan { self.people = latest }
          } catch is CancellationError { throw CancellationError() } catch {
            self.peopleErrorMessage = error.localizedDescription
          }
        } while self.needsPeopleScan
        self.peopleScanTask = nil
        self.isScanningPeople = false
        self.applyPeopleResults()
      } catch {
        guard let self, self.peopleScanID == scanID else { return }
        self.peopleScanTask = nil
        self.isScanningPeople = false
      }
    }
  }

  private func applyPeopleResults() {
    guard case .person(let id) = selectedDestination, refreshTask == nil,
      let folderTree
    else { return }
    apply(
      MediaBrowserSnapshot(
        folderTree: folderTree, selectedFolder: nil,
        mediaItems: people.first { $0.id == id }?.items ?? []), sequence: refreshSequence)
  }

  private func refresh(
    after delay: Duration = .zero,
    showsLoading: Bool = false,
    rescanDuplicates: Bool = false
  ) async {
    if rescanDuplicates {
      startDuplicateScan(invalidate: true, after: delay)
      startPeopleScan(invalidate: true, after: delay)
      startPersonSearch(after: delay)
    }
    let task = scheduleRefresh(after: delay, showsLoading: showsLoading)
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func scheduleFileChangeRefresh() {
    guard !isMutatingDuplicateFiles else { return }
    startDuplicateScan(invalidate: true, after: fileChangeRefreshDelay)
    startPeopleScan(invalidate: true, after: fileChangeRefreshDelay)
    startPersonSearch(after: fileChangeRefreshDelay)
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
    let showsDuplicates = isShowingDuplicates
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
        let snapshot: MediaBrowserSnapshot
        if showsDuplicates {
          self.startDuplicateScan()
          if self.duplicateScanResult == nil { await self.duplicateScanTask?.value }
          let currentFolderTree: MediaFolder? =
            if case .folder = destination {
              try await repository.snapshot(
                of: rootFolder, destination: destination, sort: sort
              ).folderTree
            } else {
              nil
            }
          try Task.checkCancellation()
          guard let result = self.duplicateScanResult else { throw CancellationError() }
          let duplicates = try result.get()
          if let currentFolderTree {
            snapshot = MediaBrowserSnapshot(
              folderTree: currentFolderTree, selectedFolder: nil,
              mediaItems: [], sections: duplicates.sections)
          } else {
            snapshot = duplicates
          }
        } else {
          let base = try await repository.snapshot(
            of: rootFolder,
            destination: destination,
            sort: sort
          )
          if case .person(let id) = destination {
            self.startPeopleScan()
            snapshot = MediaBrowserSnapshot(
              folderTree: base.folderTree, selectedFolder: nil,
              mediaItems: self.people.first { $0.id == id }?.items ?? [])
          } else if destination == .personSearch {
            snapshot = MediaBrowserSnapshot(
              folderTree: base.folderTree, selectedFolder: nil, mediaItems: self.personSearchItems)
          } else {
            if destination == .people { self.startPeopleScan() }
            snapshot = base
          }
        }
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

  private func applyDuplicateProgress(_ snapshot: MediaBrowserSnapshot) {
    if showsFolderDuplicates, case .folder(let id) = selectedDestination,
      selectedFolder?.id != id
    {
      return
    }
    // A scan's folder tree may predate the current sidebar selection.
    let current = MediaBrowserSnapshot(
      folderTree: showsFolderDuplicates ? (folderTree ?? snapshot.folderTree) : snapshot.folderTree,
      selectedFolder: nil, mediaItems: [], sections: snapshot.sections)
    apply(current, sequence: refreshSequence)
  }

  private func apply(_ snapshot: MediaBrowserSnapshot, sequence: Int) {
    let snapshot =
      if showsFolderDuplicates, case .folder(let id) = selectedDestination {
        mediaRepository.folderDuplicateSnapshot(from: snapshot, in: id)
      } else {
        snapshot
      }
    folderTree = snapshot.folderTree
    selectedFolder = snapshot.selectedFolder
    if case .folders = selectedDestination {
      let ids = Set(selectedFolders.map(\.id))
      selectedDestination = .folders(ids)
      if ids.count == 1, let remaining = selectedFolders.first {
        selectedFolder = remaining
      } else if ids.isEmpty {
        selectedDestination = .recents
        Task { await self.refresh(showsLoading: true) }
      }
    }
    if let selectedFolder {
      selectedDestination = .folder(selectedFolder.id)
      selectedDestinationName = selectedFolder.name
    } else if case .folders = selectedDestination {
      selectedDestinationName = "\(selectedFolders.count) Folders"
    } else if selectedDestination == .duplicates {
      selectedDestinationName = "Duplicates"
    } else if case .person(let id) = selectedDestination {
      if let person = people.first(where: { $0.id == id }) {
        selectedDestinationName = person.name
      } else if !isScanningPeople {
        selectedDestination = .people
        selectedDestinationName = "People"
      }
    } else if selectedDestination == .people {
      selectedDestinationName = "People"
    } else if selectedDestination == .personSearch {
      selectedDestinationName = "Search for person"
    } else {
      showsFolderDuplicates = false
      selectedDestination = .recents
      selectedDestinationName = "Recents"
    }
    mediaSections = snapshot.sections
    updatePreferredDuplicates()
    mediaItems = snapshot.mediaItems
    mediaItemsByID = snapshot.mediaItemsByID
    mediaItemsRevision &+= 1
    let openMediaCapability = openedMedia.flatMap { media in
      snapshot.mediaItemsByID[media.item.id].flatMap { _ in
        fileOperationCapabilities[media.item.id.url.standardizedFileURL]
      }
    }
    fileOperationCapabilities.removeAll()
    if let openedMedia, let openMediaCapability {
      fileOperationCapabilities[openedMedia.item.id.url.standardizedFileURL] = openMediaCapability
    }
    errorMessage = nil
    for selected in selectedFolders {
      Task { await self.loadFileOperationCapabilities(for: .folder(selected)) }
    }

    if let selectedMediaID, snapshot.mediaItemsByID[selectedMediaID] == nil {
      self.selectedMediaID = nil
    }
    mediaThumbnails = mediaThumbnails.filter {
      guard let current = snapshot.mediaItemsByID[$0.key] else { return false }
      return loadedThumbnailItems[$0.key] == current
    }
    loadedThumbnailItems = loadedThumbnailItems.filter {
      snapshot.mediaItemsByID[$0.key] == $0.value
    }
    thumbnailLoadIDs = thumbnailLoadIDs.filter { snapshot.mediaItemsByID[$0.key] != nil }
    if let openedMedia, snapshot.mediaItemsByID[openedMedia.item.id] == nil {
      self.openedMedia = nil
      viewerMode = nil
      resetZoom()
    }
    finishRefresh(sequence)
  }

  private func applyRefreshError(_ error: any Error, sequence: Int) {
    mediaSections = []
    updatePreferredDuplicates()
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
      scheduleRefresh(after: fileChangeRefreshDelay)
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
        if resultURL == nil { showsFolderDuplicates = false }
      }

      await refresh(after: fileChangeRefreshDelay, rescanDuplicates: true)
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
