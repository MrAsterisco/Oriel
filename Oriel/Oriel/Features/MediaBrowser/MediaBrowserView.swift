import AVKit
import FactoryKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#endif

struct MediaBrowserView: View {
  @FocusState private var isMediaViewerFocused: Bool
  @State private var deleteTarget: FileOperationTarget?
  @State private var fileInfo: FileItemInfo?
  @State private var model: any MediaBrowserFeatureModelProtocol
  @State private var moveTarget: FileOperationTarget?
  @State private var namePrompt: FileNamePrompt?
  @State private var proposedName = ""

  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
  #endif

  init(folder: Folder) {
    _model = State(initialValue: Container.shared.mediaBrowserFeatureModel(folder))
  }

  init(model: any MediaBrowserFeatureModelProtocol) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationSplitView {
      folderSidebar
        .disabled(model.viewerMode != nil)
        .navigationTitle(model.folderTree?.name ?? "Folders")
        .searchable(
          text: Binding(
            get: { model.folderSearchText },
            set: { model.setFolderSearchText($0) }
          ),
          placement: .sidebar,
          prompt: "Search Folders"
        )
    } detail: {
      detail
        .navigationTitle(navigationTitle)
        .toolbar {
          if model.openedMedia != nil {
            ToolbarItem(placement: .navigation) {
              if model.viewerMode == nil {
                Button("Back", systemImage: "chevron.backward") {
                  model.closeMedia()
                }
              } else {
                Button("Cancel Crop", systemImage: "xmark") {
                  model.cancelViewerMode()
                }
                .disabled(model.isSavingViewerMode)
              }
            }
            if case .picture(let picture) = model.openedMedia, model.viewerMode == nil {
              ToolbarItemGroup(placement: .primaryAction) {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                  model.zoomOut()
                  isMediaViewerFocused = true
                }
                .disabled(model.zoomScale == 1)

                Button("Reset Zoom", systemImage: "arrow.counterclockwise") {
                  model.resetZoom()
                  isMediaViewerFocused = true
                }
                .disabled(model.zoomScale == 1 && model.panOffset == .zero)

                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                  model.zoomIn()
                  isMediaViewerFocused = true
                }
                .disabled(model.zoomScale == 8)

                if model.fileOperationCapabilities[picture.item.id.url.standardizedFileURL]?
                  .canModify == true
                {
                  Button("Crop", systemImage: "crop") {
                    model.beginCrop()
                    isMediaViewerFocused = true
                  }
                }
              }
            }
          } else if case .folder = model.selectedDestination {
            ToolbarItem(placement: .primaryAction) {
              sortMenu
            }
          }

          if let selectedMediaItem, model.viewerMode == nil {
            ToolbarItem(placement: .primaryAction) {
              Menu("File Actions", systemImage: "ellipsis.circle") {
                mediaItemMenu(for: selectedMediaItem)
              }
            }
          } else if let selectedFolder = model.selectedFolder {
            ToolbarItem(placement: .primaryAction) {
              Menu("Folder Actions", systemImage: "ellipsis.circle") {
                folderMenu(for: selectedFolder)
              }
            }
          }
        }
    }
    .task { await model.run() }
    .alert(
      model.alertTitle,
      isPresented: Binding(
        get: { model.alertMessage != nil },
        set: { if !$0 { model.dismissAlert() } }
      )
    ) {
      Button("OK") { model.dismissAlert() }
    } message: {
      Text(model.alertMessage ?? "")
    }
    .alert(
      namePrompt?.title ?? "",
      isPresented: namePromptIsPresented,
      presenting: namePrompt
    ) { prompt in
      TextField(prompt.placeholder, text: $proposedName)
      Button("Cancel", role: .cancel) {}
      Button(prompt.actionTitle) { perform(prompt) }
    }
    .confirmationDialog(
      deleteTarget.map { "Delete \($0.name)?" } ?? "Delete Item?",
      isPresented: deleteConfirmationIsPresented,
      presenting: deleteTarget
    ) { target in
      Button("Delete Permanently", role: .destructive) {
        Task { await model.delete(target) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { target in
      if target.isFolder {
        Text("This permanently deletes the folder and all of its contents.")
      } else {
        Text("This permanently deletes the file. This action can’t be undone.")
      }
    }
    .sheet(item: $fileInfo) { info in
      FileInfoView(info: info)
    }
    .fileImporter(
      isPresented: movePickerIsPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      guard let target = moveTarget else { return }
      moveTarget = nil
      guard case .success(let urls) = result, let destinationURL = urls.first else { return }
      Task { await model.move(target, to: destinationURL) }
    }
  }

  @ViewBuilder
  private var folderSidebar: some View {
    List(selection: selectedDestination) {
      Label("Recents", systemImage: "clock")
        .tag(MediaBrowserDestination.recents)

      if let folderTree = model.filteredFolderTree {
        Section("Folders") {
          OutlineGroup([folderTree], children: \.children) { folder in
            FolderSidebarRow(folder: folder) { sources, destination, operation in
              Task {
                await model.transfer(sources, to: destination, operation: operation)
              }
            }
            .tag(MediaBrowserDestination.folder(folder.id))
            .contextMenu {
              folderMenu(for: folder)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let selectedFolder = model.selectedFolder, model.viewerMode == nil {
      detailContent
        .mediaDropDestination(folder: selectedFolder) { sources, destination, operation in
          Task {
            await model.transfer(sources, to: destination, operation: operation)
          }
        }
        .contextMenu {
          folderBackgroundMenu(for: selectedFolder)
        }
    } else {
      detailContent
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    ZStack {
      mediaBrowserContent
        .opacity(isMediaBrowserVisible ? 1 : 0)
        .allowsHitTesting(isMediaBrowserVisible)
        .accessibilityHidden(!isMediaBrowserVisible)

      if let openedMedia = model.openedMedia {
        switch openedMedia {
        case .picture(let picture):
          pictureView(picture)
        case .video(let item):
          videoView(item)
        }
      } else if !isMediaBrowserVisible {
        ProgressView("Opening Media…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onKeyPress(.escape) {
      guard model.openedMedia != nil else { return .ignored }
      if model.viewerMode == nil {
        model.closeMedia()
      } else {
        model.cancelViewerMode()
      }
      return .handled
    }
  }

  @ViewBuilder
  private var mediaBrowserContent: some View {
    if model.isLoading {
      ProgressView("Loading Media…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let errorMessage = model.errorMessage {
      ContentUnavailableView {
        Label("Couldn’t Read Folder", systemImage: "folder.badge.questionmark")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Try Again") { Task { await model.retry() } }
      }
    } else if model.mediaItems.isEmpty {
      ContentUnavailableView(
        "No Pictures or Videos",
        systemImage: "photo.on.rectangle.angled",
        description: Text(emptyStateDescription)
      )
    } else {
      mediaGrid
    }
  }

  private var isMediaBrowserVisible: Bool {
    model.openedMedia == nil && !model.isLoadingMedia
  }

  @ViewBuilder
  private var mediaGrid: some View {
    #if os(macOS)
      MacMediaCollectionView(
        items: model.mediaItems,
        itemsByID: model.mediaItemsByID,
        itemsRevision: model.mediaItemsRevision,
        selectedMediaID: model.selectedMediaID,
        isViewingRecents: model.selectedDestination == .recents,
        thumbnails: model.mediaThumbnails,
        capabilities: { capabilities(for: .media($0)) },
        openingApplications: { model.openingApplications[FileOperationTarget.media($0).id] },
        onSelect: { model.selectMedia($0) },
        onActivate: { item in Task { await model.activateMedia(item) } },
        onLoadThumbnail: { item in await model.loadThumbnail(for: item) },
        onLoadOpeningApplications: { item in
          Task { await model.loadOpeningApplications(for: .media(item)) }
        },
        onDiscardThumbnail: { model.discardThumbnail(for: $0) },
        onLoadCapabilities: { item in
          Task { await model.loadFileOperationCapabilities(for: .media(item)) }
        },
        onMenuAction: performMacMediaMenuAction,
        onOpenWith: { item, application in
          Task { await model.open(.media(item), with: application.id) }
        }
      )
    #else
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 0)],
          spacing: 0
        ) {
          ForEach(model.mediaItems) { item in
            mediaCell(for: item)
              .task(id: item) { await model.loadThumbnail(for: item) }
              .onDisappear { model.discardThumbnail(for: item) }
          }
        }
      }
      .contentShape(.rect)
      .onTapGesture { model.selectMedia(nil) }
    #endif
  }

  private var sortMenu: some View {
    Menu {
      ForEach(MediaSortOption.allCases, id: \.self) { option in
        Button {
          Task { await model.selectSortOption(option) }
        } label: {
          Label(sortLabel(for: option), systemImage: sortSymbol(for: option))
        }
      }
    } label: {
      Label("Sort", systemImage: "arrow.up.arrow.down")
    }
    .help("Sort Media")
  }

  @ViewBuilder
  private func mediaCell(for item: MediaItem) -> some View {
    MediaCell(
      item: item,
      thumbnail: model.thumbnail(for: item),
      isSelected: model.selectedMediaID == item.id
    )
    .contentShape(.rect)
    .onTapGesture {
      model.selectMedia(item)
    }
    .simultaneousGesture(
      TapGesture(count: 2)
        .onEnded { Task { await model.activateMedia(item) } }
    )
    .accessibilityAction {
      Task { await model.activateMedia(item) }
    }
    .mediaDraggable(source: model.dragSource(for: item)) {
      model.selectMedia(item)
    }
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.2)
        .onEnded { _ in model.selectMedia(item) }
    )
    .contextMenu {
      mediaItemMenu(for: item)
    }
  }

  private func pictureView(_ picture: PictureContent) -> some View {
    Group {
      switch model.viewerMode {
      case .crop(let crop):
        PictureCropViewer(
          image: picture.image.cgImage,
          crop: crop,
          onCropRectChanged: model.setCropRect
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
          cropBanner(crop)
        }
      case nil:
        PictureViewer(
          image: picture.image.cgImage,
          zoomScale: model.zoomScale,
          panOffset: model.panOffset
        ) { zoomScale, panOffset in
          model.setViewerTransform(zoomScale: zoomScale, panOffset: panOffset)
        }
        .contextMenu {
          mediaItemMenu(for: picture.item)
        }
      }
    }
    .focusable()
    .focused($isMediaViewerFocused)
    .focusEffectDisabled()
    .onAppear { isMediaViewerFocused = true }
    .onKeyPress(keys: [.leftArrow, .upArrow, .rightArrow, .downArrow]) { keyPress in
      guard model.viewerMode == nil else { return .ignored }
      let direction: MediaNavigationDirection
      switch keyPress.key {
      case .leftArrow, .upArrow:
        direction = .previous
      case .rightArrow, .downArrow:
        direction = .next
      default:
        return .ignored
      }
      Task { await model.navigate(direction) }
      return .handled
    }
    .task(id: picture.item) {
      await model.loadFileOperationCapabilities(for: .media(picture.item))
    }
  }

  private func cropBanner(_ crop: PictureCrop) -> some View {
    VStack(spacing: 0) {
      Divider()
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          cropDescription(crop)
            .fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 24)
          cropActions
            .fixedSize()
        }

        VStack(alignment: .leading, spacing: 12) {
          cropDescription(crop)
          cropActions
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
      .padding()
    }
    .background(.bar)
  }

  private func cropDescription(_ crop: PictureCrop) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "crop")
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Crop Picture")
          .font(.headline)
        Text(
          "Drag the selection or its corners · \(crop.pixelRect.width) × \(crop.pixelRect.height) pixels"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
    }
  }

  private var cropActions: some View {
    HStack(spacing: 10) {
      if model.isSavingViewerMode {
        ProgressView()
          .controlSize(.small)
      }
      Button("Cancel", role: .cancel) {
        model.cancelViewerMode()
      }
      .disabled(model.isSavingViewerMode)
      .keyboardShortcut(.cancelAction)

      Button("Save a Copy") {
        Task { await model.saveCrop(asCopy: true) }
      }
      .disabled(model.isSavingViewerMode)
      .buttonStyle(.bordered)

      Button("Save") {
        Task { await model.saveCrop(asCopy: false) }
      }
      .disabled(model.isSavingViewerMode)
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
    }
  }

  private func videoView(_ item: MediaItem) -> some View {
    MediaVideoPlayer(item: item) { direction in
      Task { await model.navigate(direction) }
    }
    .id(item.id)
    .contextMenu {
      mediaItemMenu(for: item)
    }
  }

  @ViewBuilder
  private func mediaItemMenu(for item: MediaItem) -> some View {
    let target = FileOperationTarget.media(item)
    let capabilities = capabilities(for: target)

    Group {
      Button("Open", systemImage: "arrow.up.forward.app") {
        Task { await model.activateMedia(item) }
      }
      .onAppear {
        Task { await model.loadFileOperationCapabilities(for: target) }
      }
      #if os(macOS)
        Menu("Open With", systemImage: "square.stack.3d.up") {
          if let applications = model.openingApplications[target.id] {
            if applications.isEmpty {
              Text("No Applications Found")
            } else {
              ForEach(applications) { application in
                Button(application.name) {
                  Task { await model.open(target, with: application.id) }
                }
              }
            }
          } else {
            ProgressView("Loading Applications…")
          }
        }
      #endif
      ShareLink(item: item.id.url) {
        Label("Share…", systemImage: "square.and.arrow.up")
      }

      Divider()

      if capabilities.canModify {
        Button("Rename…", systemImage: "pencil") { presentRename(target) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
          Task { await model.duplicate(target) }
        }
      }
      Button("Copy", systemImage: "doc.on.doc") {
        Task { await model.copy(target) }
      }
      if capabilities.canModify {
        Button("Move To…", systemImage: "folder") { moveTarget = target }
      }
      if model.selectedDestination == .recents {
        Button("Reveal in Folder", systemImage: "folder") {
          Task { await model.revealInFolder(item) }
        }
      }
      #if os(macOS)
        Button("Show in Finder", systemImage: "finder") {
          Task { await model.reveal(target) }
        }
      #endif
      Button("Get Info", systemImage: "info.circle") { presentInfo(target) }

      if capabilities.canModify {
        Divider()
        destructiveButton(for: target, capabilities: capabilities)
      }
    }
  }

  @ViewBuilder
  private func folderMenu(for folder: MediaFolder) -> some View {
    let target = FileOperationTarget.folder(folder)
    let capabilities = capabilities(for: target)
    let isRoot = folder.id == model.folderTree?.id

    Group {
      Button("Open", systemImage: "folder") {
        Task { await model.selectDestination(.folder(folder.id)) }
      }
      .onAppear {
        Task {
          await model.loadFileOperationCapabilities(for: target)
          #if os(macOS)
            await model.loadOpeningApplications(for: target)
          #endif
        }
      }
      #if os(macOS)
        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
          open(folder, asTab: false)
        }
        Button("Open in New Tab", systemImage: "plus.rectangle.on.rectangle") {
          open(folder, asTab: true)
        }
      #endif

      Divider()

      if capabilities.canModifyContents {
        Button("New Folder", systemImage: "folder.badge.plus") { presentNewFolder(in: folder) }
        Button("Paste", systemImage: "doc.on.clipboard") {
          Task { await model.paste(into: folder) }
        }
      }
      if !isRoot, capabilities.canModify {
        Button("Rename…", systemImage: "pencil") { presentRename(target) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
          Task { await model.duplicate(target) }
        }
      }
      Button("Copy", systemImage: "doc.on.doc") {
        Task { await model.copy(target) }
      }
      if !isRoot, capabilities.canModify {
        Button("Move To…", systemImage: "folder") { moveTarget = target }
      }
      ShareLink(item: folder.id.url) {
        Label("Share…", systemImage: "square.and.arrow.up")
      }
      #if os(macOS)
        Button("Show in Finder", systemImage: "finder") {
          Task { await model.reveal(target) }
        }
      #endif
      Button("Get Info", systemImage: "info.circle") { presentInfo(target) }

      if !isRoot, capabilities.canModify {
        Divider()
        destructiveButton(for: target, capabilities: capabilities)
      }
    }
  }

  @ViewBuilder
  private func folderBackgroundMenu(for folder: MediaFolder) -> some View {
    let target = FileOperationTarget.folder(folder)
    let capabilities = capabilities(for: target)

    Group {
      if capabilities.canModifyContents {
        Button("New Folder", systemImage: "folder.badge.plus") { presentNewFolder(in: folder) }
        Button("Paste", systemImage: "doc.on.clipboard") {
          Task { await model.paste(into: folder) }
        }
      }
      #if os(macOS)
        Button("Show in Finder", systemImage: "finder") {
          Task { await model.reveal(target) }
        }
      #endif
      Button("Get Info", systemImage: "info.circle") { presentInfo(target) }
        .onAppear {
          Task { await model.loadFileOperationCapabilities(for: target) }
        }
    }
  }

  @ViewBuilder
  private func destructiveButton(
    for target: FileOperationTarget,
    capabilities: FileOperationCapabilities
  ) -> some View {
    if capabilities.canMoveToTrash {
      Button("Move to Trash", systemImage: "trash", role: .destructive) {
        Task { await model.moveToTrash(target) }
      }
    } else {
      Button("Delete…", systemImage: "trash", role: .destructive) {
        deleteTarget = target
      }
    }
  }

  private func capabilities(for target: FileOperationTarget) -> FileOperationCapabilities {
    if let capabilities = model.fileOperationCapabilities[target.id] { return capabilities }
    return FileOperationCapabilities(
      canModify: true,
      canModifyContents: target.isFolder,
      canMoveToTrash: defaultTrashAvailability
    )
  }

  private func presentRename(_ target: FileOperationTarget) {
    proposedName = target.editableName
    namePrompt = .rename(target)
  }

  private func presentNewFolder(in folder: MediaFolder) {
    proposedName = "New Folder"
    namePrompt = .newFolder(folder)
  }

  private func presentInfo(_ target: FileOperationTarget) {
    Task {
      if let info = await model.fileInfo(for: target) {
        fileInfo = info
      }
    }
  }

  private func perform(_ prompt: FileNamePrompt) {
    namePrompt = nil
    switch prompt {
    case .rename(let target):
      Task { await model.rename(target, to: proposedName) }
    case .newFolder(let folder):
      Task { await model.createFolder(named: proposedName, in: folder) }
    }
  }

  #if os(macOS)
    private func performMacMediaMenuAction(
      _ action: MacMediaMenuAction,
      item: MediaItem
    ) {
      let target = FileOperationTarget.media(item)
      switch action {
      case .open:
        Task { await model.activateMedia(item) }
      case .rename:
        presentRename(target)
      case .duplicate:
        Task { await model.duplicate(target) }
      case .copy:
        Task { await model.copy(target) }
      case .move:
        moveTarget = target
      case .revealInFolder:
        Task { await model.revealInFolder(item) }
      case .reveal:
        Task { await model.reveal(target) }
      case .info:
        presentInfo(target)
      case .trash:
        Task { await model.moveToTrash(target) }
      case .delete:
        deleteTarget = target
      }
    }

    private func open(_ folder: MediaFolder, asTab: Bool) {
      Task {
        guard let id = await model.prepareFolderForOpening(folder) else { return }
        let window = NSApp.keyWindow
        let previousMode = window?.tabbingMode
        window?.tabbingMode = asTab ? .preferred : .disallowed
        openWindow(id: OrielWindowID.folder, value: Optional(id))
        window?.tabbingMode = previousMode ?? .automatic
      }
    }
  #endif

  private var selectedDestination: Binding<MediaBrowserDestination?> {
    Binding(
      get: { model.selectedDestination },
      set: { destination in
        guard let destination else { return }
        Task { await model.selectDestination(destination) }
      }
    )
  }

  private var selectedMediaItem: MediaItem? {
    if let openedMedia = model.openedMedia { return openedMedia.item }
    guard let selectedMediaID = model.selectedMediaID else { return nil }
    return model.mediaItemsByID[selectedMediaID]
  }

  private var namePromptIsPresented: Binding<Bool> {
    Binding(
      get: { namePrompt != nil },
      set: { if !$0 { namePrompt = nil } }
    )
  }

  private var deleteConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { deleteTarget != nil },
      set: { if !$0 { deleteTarget = nil } }
    )
  }

  private var movePickerIsPresented: Binding<Bool> {
    Binding(get: { moveTarget != nil }, set: { _ in })
  }

  private var defaultTrashAvailability: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }

  private var navigationTitle: String {
    if let openedMedia = model.openedMedia { return openedMedia.item.name }
    return model.selectedDestinationName
  }

  private var emptyStateDescription: String {
    if model.selectedDestination == .recents {
      return "This folder and its subfolders don’t contain supported media."
    }
    return "This folder doesn’t contain supported media."
  }

  private func sortLabel(for option: MediaSortOption) -> String {
    let name: String
    switch option {
    case .mostRecent: name = "Most Recent"
    case .name: name = "Name"
    case .size: name = "Size"
    }

    guard model.mediaSort.option == option else { return "\(name) (Off)" }
    let direction = model.mediaSort.direction == .ascending ? "Ascending" : "Descending"
    return "\(name) (\(direction))"
  }

  private func sortSymbol(for option: MediaSortOption) -> String {
    guard model.mediaSort.option == option else { return "circle" }
    return model.mediaSort.direction == .ascending ? "arrow.up" : "arrow.down"
  }
}

private struct MediaVideoPlayer: View {
  let item: MediaItem
  let onNavigate: (MediaNavigationDirection) -> Void

  @FocusState private var isFocused: Bool
  @State private var player: AVPlayer

  init(item: MediaItem, onNavigate: @escaping (MediaNavigationDirection) -> Void) {
    self.item = item
    self.onNavigate = onNavigate
    _player = State(initialValue: AVPlayer(url: item.id.url))
  }

  var body: some View {
    ZStack {
      Color.black
      VideoPlayer(player: player)
        .padding()
    }
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    .onAppear {
      isFocused = true
      player.play()
    }
    .onDisappear { player.pause() }
    .onKeyPress(keys: [.leftArrow, .upArrow, .rightArrow, .downArrow, .space]) {
      keyPress in
      switch keyPress.key {
      case .leftArrow, .upArrow:
        onNavigate(.previous)
      case .rightArrow, .downArrow:
        onNavigate(.next)
      case .space:
        player.timeControlStatus == .paused ? player.play() : player.pause()
      default:
        return .ignored
      }
      return .handled
    }
  }
}

private enum FileNamePrompt: Identifiable {
  case rename(FileOperationTarget)
  case newFolder(MediaFolder)

  var id: String {
    switch self {
    case .rename(let target): "rename:\(target.id.path)"
    case .newFolder(let folder): "new-folder:\(folder.id.url.path)"
    }
  }

  var title: String {
    switch self {
    case .rename: "Rename"
    case .newFolder: "New Folder"
    }
  }

  var placeholder: String {
    switch self {
    case .rename: "Name"
    case .newFolder: "Folder Name"
    }
  }

  var actionTitle: String {
    switch self {
    case .rename: "Rename"
    case .newFolder: "Create"
    }
  }
}

private struct FileInfoView: View {
  @Environment(\.dismiss) private var dismiss
  let info: FileItemInfo

  var body: some View {
    NavigationStack {
      Form {
        LabeledContent("Name", value: info.name)
        LabeledContent("Kind", value: info.kind)
        if let fileSize = info.fileSize {
          LabeledContent(
            "Size",
            value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
          )
        }
        if let dimensions {
          LabeledContent("Dimensions", value: dimensions)
        }
        if let duration = info.duration {
          LabeledContent(
            "Duration",
            value: Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
          )
        }
        if let dateAdded = info.dateAdded {
          LabeledContent("Date Added", value: dateAdded.formatted())
        }
        if let creationDate = info.creationDate {
          LabeledContent("Created", value: creationDate.formatted())
        }
        if let modificationDate = info.modificationDate {
          LabeledContent("Modified", value: modificationDate.formatted())
        }
        LabeledContent("Where", value: info.location)
      }
      .formStyle(.grouped)
      .navigationTitle("Get Info")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .frame(minWidth: 420, minHeight: 360)
  }

  private var dimensions: String? {
    guard let width = info.pixelWidth, let height = info.pixelHeight else { return nil }
    return "\(width) × \(height) pixels"
  }
}

struct MediaCell: View {
  @Environment(\.appearsActive) private var appearsActive

  let item: MediaItem
  let thumbnail: MediaThumbnail?
  let isSelected: Bool

  var body: some View {
    Rectangle()
      .fill(.quaternary)
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if let thumbnail {
          Image(decorative: thumbnail.image.cgImage, scale: 1)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: item.kind == .picture ? "photo" : "film")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
        }
      }
      .overlay {
        if item.kind == .video {
          Image(systemName: "play.circle.fill")
            .font(.system(size: 38))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.55))
        }
      }
      .clipped()
      .overlay {
        if isSelected {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(appearsActive ? Color.accentColor : Color.secondary, lineWidth: 4)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(item.name)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct FolderSidebarRow: View {
  let folder: MediaFolder
  let performTransfer:
    ([MediaTransferSource], MediaTransferDestination, MediaTransferOperation) -> Void

  var body: some View {
    Label(folder.name, systemImage: "folder")
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
      .mediaDropDestination(folder: folder, perform: performTransfer)
  }
}

private struct MediaDropDestinationModifier: ViewModifier {
  let folder: MediaFolder
  let perform: ([MediaTransferSource], MediaTransferDestination, MediaTransferOperation) -> Void
  @State private var isTargeted = false

  @ViewBuilder
  func body(content: Content) -> some View {
    #if os(macOS)
      content
        .dropDestination(for: MediaTransferSource.self) { sources, session in
          guard let operation = mediaTransferOperation(for: dropOperation(session)) else { return }
          perform(sources, MediaTransferDestination(folderID: folder.id), operation)
        }
        .dropConfiguration { session in
          DropConfiguration(operation: dropOperation(session))
        }
        .onDropSessionUpdated { session in
          switch session.phase {
          case .entering, .active:
            isTargeted = dropOperation(session) != .forbidden
          case .exiting, .ended, .dataTransferCompleted:
            isTargeted = false
          @unknown default:
            isTargeted = false
          }
        }
        .dropHighlight(isTargeted)
    #else
      content
        .dropDestination(for: MediaTransferSource.self) { sources, _ in
          perform(
            sources,
            MediaTransferDestination(folderID: folder.id),
            .copy
          )
          return true
        } isTargeted: {
          isTargeted = $0
        }
        .dropHighlight(isTargeted)
    #endif
  }

  #if os(macOS)
    private func dropOperation(_ session: DropSession) -> DropOperation {
      if let localSession = session.localSession {
        let itemIDs = localSession.draggedItemIDs(for: MediaItem.ID.self)
        if itemIDs.contains(where: {
          $0.url.deletingLastPathComponent().standardizedFileURL
            == folder.id.url.standardizedFileURL
        }) {
          return .forbidden
        }
      }

      if session.suggestedOperations.contains(.move) { return .move }
      if session.suggestedOperations.contains(.copy) { return .copy }
      return .forbidden
    }

    private func mediaTransferOperation(
      for operation: DropOperation
    ) -> MediaTransferOperation? {
      switch operation {
      case .copy: .copy
      case .move: .move
      default: nil
      }
    }
  #endif
}

extension View {
  @ViewBuilder
  fileprivate func mediaDraggable(
    source: MediaTransferSource,
    onBegin: @escaping () -> Void
  ) -> some View {
    #if os(macOS)
      draggable(MediaTransferSource.self) { source }
        .dragConfiguration(DragConfiguration(allowMove: true))
        .onDragSessionUpdated { session in
          guard session.phase == .initial else { return }
          onBegin()
        }
    #else
      onDrag {
        onBegin()
        let provider = NSItemProvider()
        provider.register(source)
        return provider
      }
    #endif
  }

  fileprivate func mediaDropDestination(
    folder: MediaFolder,
    perform:
      @escaping (
        [MediaTransferSource], MediaTransferDestination, MediaTransferOperation
      ) -> Void
  ) -> some View {
    modifier(MediaDropDestinationModifier(folder: folder, perform: perform))
  }

  @ViewBuilder
  fileprivate func dropHighlight(_ isTargeted: Bool) -> some View {
    background {
      if isTargeted {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.accentColor.opacity(0.16))
      }
    }
  }
}
