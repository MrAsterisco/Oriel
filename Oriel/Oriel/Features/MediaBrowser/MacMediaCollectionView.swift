#if os(macOS)
  import AppKit
  import SwiftUI

  enum MacMediaMenuAction: Int {
    case open
    case rename
    case duplicate
    case copy
    case move
    case revealInFolder
    case reveal
    case info
    case trash
    case delete
  }

  struct MacMediaCollectionView: NSViewRepresentable {
    let items: [MediaItem]
    let sections: [MediaSection]
    let preferredDuplicateIDs: Set<MediaItem.ID>
    let isCleaningDuplicates: Bool
    let showsDuplicateActions: Bool
    let onKeepBestCopy: (MediaSection) -> Void
    let itemsByID: [MediaItem.ID: MediaItem]
    let itemsRevision: Int
    let selectedMediaID: MediaItem.ID?
    let isViewingAggregate: Bool
    let thumbnails: [MediaItem.ID: MediaThumbnail]
    let capabilities: (MediaItem) -> FileOperationCapabilities
    let openingApplications: (MediaItem) -> [FileOpeningApplication]?
    let onSelect: (MediaItem?) -> Void
    let onActivate: (MediaItem) -> Void
    let onLoadThumbnail: (MediaItem) async -> Void
    let onLoadOpeningApplications: (MediaItem) -> Void
    let onDiscardThumbnail: (MediaItem) -> Void
    let onLoadCapabilities: (MediaItem) -> Void
    let onMenuAction: (MacMediaMenuAction, MediaItem) -> Void
    let onOpenWith: (MediaItem, FileOpeningApplication) -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
      let layout = NSCollectionViewFlowLayout()
      layout.minimumInteritemSpacing = 0
      layout.minimumLineSpacing = 0
      layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

      let collectionView = MediaCollectionView()
      collectionView.collectionViewLayout = layout
      collectionView.delegate = context.coordinator
      collectionView.isSelectable = true
      collectionView.allowsEmptySelection = true
      collectionView.allowsMultipleSelection = false
      collectionView.backgroundColors = [.clear]
      collectionView.register(
        MediaCollectionItem.self,
        forItemWithIdentifier: MediaCollectionItem.identifier
      )
      collectionView.register(
        MediaSectionHeader.self,
        forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
        withIdentifier: MediaSectionHeader.identifier
      )
      context.coordinator.installDataSource(in: collectionView)
      collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
      collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
      collectionView.menuForItem = { [weak coordinator = context.coordinator] indexPath, view in
        coordinator?.menu(for: indexPath, relativeTo: view)
      }
      collectionView.selectionChanged = { [weak coordinator = context.coordinator] indexPath in
        coordinator?.select(indexPath)
      }
      collectionView.itemActivated = { [weak coordinator = context.coordinator] indexPath in
        coordinator?.activate(indexPath)
      }

      let scrollView = NSScrollView()
      scrollView.drawsBackground = false
      scrollView.hasVerticalScroller = true
      scrollView.documentView = collectionView
      collectionView.frame = scrollView.contentView.bounds
      collectionView.autoresizingMask = [.width]
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
      guard let collectionView = scrollView.documentView as? MediaCollectionView else { return }
      context.coordinator.parent = self
      if !context.coordinator.applySnapshotIfNeeded() {
        context.coordinator.updateVisibleItems(in: collectionView)
      }
      context.coordinator.synchronizeSelection(in: collectionView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
      coordinator.cancelThumbnailLoads()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
      var parent: MacMediaCollectionView
      private var appliedItems: [MediaItem.ID: MediaItem] = [:]
      private var appliedItemsRevision: Int?
      private var appliedSections: [MediaSection] = []
      private weak var collectionView: NSCollectionView?
      private var dataSource: NSCollectionViewDiffableDataSource<MediaItem.ID, MediaItem.ID>?
      private weak var menuAnchor: NSView?
      private var sharingPicker: NSSharingServicePicker?
      private var thumbnailTaskIDs: [MediaItem.ID: UUID] = [:]
      private var thumbnailTasks: [MediaItem.ID: Task<Void, Never>] = [:]

      init(parent: MacMediaCollectionView) {
        self.parent = parent
      }

      func installDataSource(in collectionView: NSCollectionView) {
        self.collectionView = collectionView
        dataSource = NSCollectionViewDiffableDataSource<MediaItem.ID, MediaItem.ID>(
          collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
          guard let self, let item = mediaItem(with: itemID) else { return nil }
          let collectionItem =
            collectionView.makeItem(
              withIdentifier: MediaCollectionItem.identifier,
              for: indexPath
            ) as! MediaCollectionItem
          configure(collectionItem, with: item)
          return collectionItem
        }
        dataSource?.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
          let header =
            collectionView.makeSupplementaryView(
              ofKind: kind,
              withIdentifier: MediaSectionHeader.identifier,
              for: indexPath
            ) as! MediaSectionHeader
          guard let self, parent.sections.indices.contains(indexPath.section) else { return header }
          configure(header, section: parent.sections[indexPath.section])
          return header
        }
        applySnapshotIfNeeded()
      }

      @discardableResult
      func applySnapshotIfNeeded() -> Bool {
        guard let dataSource else { return false }
        guard appliedItemsRevision != parent.itemsRevision else { return false }

        let itemIDs = parent.items.map(\.id)
        let previousItemIDs = dataSource.snapshot().itemIdentifiers
        let previousItemIDSet = Set(previousItemIDs)
        let changedItemIDs = itemIDs.filter {
          previousItemIDSet.contains($0) && appliedItems[$0] != parent.itemsByID[$0]
        }
        appliedItems = parent.itemsByID
        appliedItemsRevision = parent.itemsRevision
        let sectionsChanged = appliedSections != parent.sections
        let headerVisibilityChanged =
          appliedSections.contains { $0.title != nil }
          != parent.sections.contains { $0.title != nil }
        appliedSections = parent.sections
        guard previousItemIDs != itemIDs || !changedItemIDs.isEmpty || sectionsChanged else {
          return false
        }

        var snapshot = NSDiffableDataSourceSnapshot<MediaItem.ID, MediaItem.ID>()
        for section in parent.sections {
          snapshot.appendSections([section.id])
          snapshot.appendItems(section.items.map(\.id), toSection: section.id)
        }
        if headerVisibilityChanged { collectionView?.collectionViewLayout?.invalidateLayout() }
        snapshot.reloadItems(changedItemIDs)
        dataSource.apply(snapshot, animatingDifferences: !previousItemIDs.isEmpty) { [weak self] in
          guard let self, let collectionView = self.collectionView else { return }
          self.updateVisibleItems(in: collectionView)
          self.synchronizeSelection(in: collectionView)
        }
        return true
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
      ) -> NSSize {
        let width = collectionView.bounds.width
        let columnCount = max(Int(width / 150), 1)
        let itemWidth = min(240, floor(width / CGFloat(columnCount)))
        return NSSize(width: itemWidth, height: itemWidth)
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
      ) -> NSSize {
        guard parent.sections.indices.contains(section),
          parent.sections[section].title != nil
        else { return .zero }
        return NSSize(width: collectionView.bounds.width, height: 40)
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
      ) {
        selectionChanged(in: collectionView)
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
      ) {
        selectionChanged(in: collectionView)
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
      ) {
        guard let mediaItem = mediaItem(at: indexPath) else { return }
        if let cell = item as? MediaCollectionItem { configure(cell, with: mediaItem) }
        loadThumbnailIfNeeded(for: mediaItem)
      }

      private func loadThumbnailIfNeeded(for mediaItem: MediaItem) {
        guard parent.thumbnails[mediaItem.id] == nil, thumbnailTasks[mediaItem.id] == nil else {
          return
        }
        let taskID = UUID()
        thumbnailTaskIDs[mediaItem.id] = taskID
        thumbnailTasks[mediaItem.id] = Task { [weak self] in
          guard let self else { return }
          await parent.onLoadThumbnail(mediaItem)
          guard thumbnailTaskIDs[mediaItem.id] == taskID else { return }
          thumbnailTaskIDs[mediaItem.id] = nil
          thumbnailTasks[mediaItem.id] = nil
          if let current = parent.itemsByID[mediaItem.id], current != mediaItem {
            loadThumbnailIfNeeded(for: current)
          }
        }
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
      ) {
        guard let cell = item as? MediaCollectionItem, let mediaItem = cell.mediaItem else {
          return
        }
        cell.releaseImage()
        // Diffable updates can replace a cell while its media item remains on screen.
        Task { @MainActor [weak self, weak collectionView] in
          guard let self, let collectionView else { return }
          guard
            !collectionView.visibleItems().contains(where: {
              ($0 as? MediaCollectionItem)?.mediaItem?.id == mediaItem.id
            })
          else { return }
          thumbnailTaskIDs[mediaItem.id] = nil
          thumbnailTasks.removeValue(forKey: mediaItem.id)?.cancel()
          parent.onDiscardThumbnail(mediaItem)
        }
      }

      func cancelThumbnailLoads() {
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTaskIDs.removeAll()
        thumbnailTasks.removeAll()
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
      ) -> (any NSPasteboardWriting)? {
        guard let item = mediaItem(at: indexPath) else { return nil }
        return item.id.url as NSURL
      }

      func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItemsAt indexPaths: Set<IndexPath>
      ) {
        guard let indexPath = indexPaths.first else { return }
        select(indexPath)
      }

      func synchronizeSelection(in collectionView: NSCollectionView) {
        let selectedIndexPath = parent.selectedMediaID.flatMap {
          dataSource?.indexPath(for: $0)
        }
        let selection = selectedIndexPath.map { Set([$0]) } ?? []
        guard collectionView.selectionIndexPaths != selection else { return }
        collectionView.selectionIndexPaths = selection
      }

      private func configure(_ header: MediaSectionHeader, section: MediaSection) {
        header.configure(
          MediaSectionHeading(
            title: section.title ?? "",
            isCleaningDuplicates: parent.isCleaningDuplicates,
            showsDuplicateActions: parent.showsDuplicateActions,
            onKeepBestCopy: { [weak self] in self?.parent.onKeepBestCopy(section) }))
      }

      func updateVisibleItems(in collectionView: NSCollectionView) {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
          ofKind: NSCollectionView.elementKindSectionHeader)
        {
          guard parent.sections.indices.contains(indexPath.section),
            let header = collectionView.supplementaryView(
              forElementKind: NSCollectionView.elementKindSectionHeader, at: indexPath)
              as? MediaSectionHeader
          else { continue }
          configure(header, section: parent.sections[indexPath.section])
        }
        for collectionItem in collectionView.visibleItems() {
          guard let indexPath = collectionView.indexPath(for: collectionItem),
            let collectionItem = collectionItem as? MediaCollectionItem
          else {
            continue
          }
          configure(collectionItem, at: indexPath)
          if let item = mediaItem(at: indexPath) { loadThumbnailIfNeeded(for: item) }
        }
      }

      func select(_ indexPath: IndexPath?) {
        parent.onSelect(indexPath.flatMap(mediaItem(at:)))
      }

      func activate(_ indexPath: IndexPath) {
        guard let item = mediaItem(at: indexPath) else { return }
        parent.onActivate(item)
      }

      func menu(for indexPath: IndexPath, relativeTo view: NSView) -> NSMenu? {
        guard let item = mediaItem(at: indexPath) else { return nil }
        parent.onSelect(item)
        parent.onLoadCapabilities(item)
        parent.onLoadOpeningApplications(item)
        menuAnchor = view

        let menu = NSMenu()
        add(.open, title: "Open", symbol: "arrow.up.forward.app", item: item, to: menu)
        addOpenWith(item, to: menu)
        addShare(item, to: menu)
        menu.addItem(.separator())

        let capabilities = parent.capabilities(item)
        if capabilities.canModify {
          add(.rename, title: "Rename…", symbol: "pencil", item: item, to: menu)
          add(.duplicate, title: "Duplicate", symbol: "plus.square.on.square", item: item, to: menu)
        }
        add(.copy, title: "Copy", symbol: "doc.on.doc", item: item, to: menu)
        if capabilities.canModify {
          add(.move, title: "Move To…", symbol: "folder", item: item, to: menu)
        }
        if parent.isViewingAggregate {
          add(.revealInFolder, title: "Reveal in Folder", symbol: "folder", item: item, to: menu)
        }
        add(.reveal, title: "Show in Finder", symbol: "finder", item: item, to: menu)
        add(.info, title: "Get Info", symbol: "info.circle", item: item, to: menu)

        if capabilities.canModify {
          menu.addItem(.separator())
          add(
            capabilities.canMoveToTrash ? .trash : .delete,
            title: capabilities.canMoveToTrash ? "Move to Trash" : "Delete…",
            symbol: "trash",
            item: item,
            to: menu
          )
        }
        return menu
      }

      private func configure(_ collectionItem: MediaCollectionItem, at indexPath: IndexPath) {
        guard let item = mediaItem(at: indexPath) else { return }
        configure(collectionItem, with: item)
      }

      private func configure(_ collectionItem: MediaCollectionItem, with item: MediaItem) {
        collectionItem.configure(
          item: item, thumbnail: parent.thumbnails[item.id],
          isPreferredDuplicate: parent.preferredDuplicateIDs.contains(item.id))
      }

      private func selectionChanged(in collectionView: NSCollectionView) {
        select(collectionView.selectionIndexPaths.first)
      }

      private func mediaItem(at indexPath: IndexPath) -> MediaItem? {
        guard let itemID = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        return mediaItem(with: itemID)
      }

      private func mediaItem(with id: MediaItem.ID) -> MediaItem? {
        parent.itemsByID[id]
      }

      private func add(
        _ action: MacMediaMenuAction,
        title: String,
        symbol: String,
        item: MediaItem,
        to menu: NSMenu
      ) {
        let menuItem = NSMenuItem(
          title: title,
          action: #selector(performMenuAction(_:)),
          keyEquivalent: ""
        )
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menuItem.representedObject = item.id.url as NSURL
        menuItem.tag = action.rawValue
        menuItem.target = self
        menu.addItem(menuItem)
      }

      private func addShare(_ item: MediaItem, to menu: NSMenu) {
        let menuItem = NSMenuItem(
          title: "Share…",
          action: #selector(share(_:)),
          keyEquivalent: ""
        )
        menuItem.image = NSImage(
          systemSymbolName: "square.and.arrow.up",
          accessibilityDescription: nil
        )
        menuItem.representedObject = item.id.url as NSURL
        menuItem.target = self
        menu.addItem(menuItem)
      }

      private func addOpenWith(_ item: MediaItem, to menu: NSMenu) {
        let menuItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        menuItem.image = NSImage(
          systemSymbolName: "square.stack.3d.up",
          accessibilityDescription: nil
        )

        let submenu = NSMenu(title: "Open With")
        if let applications = parent.openingApplications(item) {
          if applications.isEmpty {
            submenu.addItem(withTitle: "No Applications Found", action: nil, keyEquivalent: "")
          } else {
            for application in applications {
              let applicationItem = NSMenuItem(
                title: application.name,
                action: #selector(openWith(_:)),
                keyEquivalent: ""
              )
              applicationItem.representedObject = OpenWithMenuSelection(
                mediaID: item.id,
                application: application
              )
              applicationItem.target = self
              submenu.addItem(applicationItem)
            }
          }
        } else {
          submenu.addItem(withTitle: "Loading Applications…", action: nil, keyEquivalent: "")
        }
        menuItem.submenu = submenu
        menu.addItem(menuItem)
      }

      @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = MacMediaMenuAction(rawValue: sender.tag),
          let item = mediaItem(representedBy: sender)
        else {
          return
        }
        parent.onMenuAction(action, item)
      }

      @objc private func share(_ sender: NSMenuItem) {
        guard let item = mediaItem(representedBy: sender), let menuAnchor else { return }
        let picker = NSSharingServicePicker(items: [item.id.url])
        sharingPicker = picker
        picker.show(relativeTo: menuAnchor.bounds, of: menuAnchor, preferredEdge: .minY)
      }

      @objc private func openWith(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? OpenWithMenuSelection,
          let item = mediaItem(with: selection.mediaID)
        else {
          return
        }
        parent.onOpenWith(item, selection.application)
      }

      private func mediaItem(representedBy menuItem: NSMenuItem) -> MediaItem? {
        guard let url = menuItem.representedObject as? NSURL else { return nil }
        return parent.items.first {
          $0.id.url.standardizedFileURL == (url as URL).standardizedFileURL
        }
      }

      private struct OpenWithMenuSelection {
        let mediaID: MediaItem.ID
        let application: FileOpeningApplication
      }
    }
  }

  private final class MediaSectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("MediaSectionHeader")
    private var hostingView: NSHostingView<MediaSectionHeading>?

    func configure(_ content: MediaSectionHeading) {
      if let hostingView {
        hostingView.rootView = content
        return
      }
      let hostingView = NSHostingView(rootView: content)
      hostingView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(hostingView)
      NSLayoutConstraint.activate([
        hostingView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        hostingView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        hostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
      self.hostingView = hostingView
    }
  }

  private final class MediaCollectionView: NSCollectionView {
    var itemActivated: ((IndexPath) -> Void)?
    var menuForItem: ((IndexPath, NSView) -> NSMenu?)?
    var selectionChanged: ((IndexPath?) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
      let widthChanged = frame.width != newSize.width
      super.setFrameSize(newSize)
      if widthChanged {
        collectionViewLayout?.invalidateLayout()
      }
    }

    override func mouseDown(with event: NSEvent) {
      // A double-click recognizer delays the first click, making selection feel sluggish.
      let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
      super.mouseDown(with: event)
      if event.clickCount == 2, let indexPath {
        itemActivated?(indexPath)
      }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      guard let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
      else {
        return super.menu(for: event)
      }
      let selection = Set([indexPath])
      if selectionIndexPaths != selection {
        selectionIndexPaths = selection
        selectionChanged?(indexPath)
      }
      return menuForItem?(indexPath, item(at: indexPath)?.view ?? self)
    }
  }

  final class MediaCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MediaCollectionItem")

    private var hostingView: NSHostingView<MediaCell>?
    private(set) var mediaItem: MediaItem?
    private var thumbnail: MediaThumbnail?
    private var isPreferredDuplicate = false

    override var isSelected: Bool {
      didSet { updateContent() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
      didSet { updateContent() }
    }

    override func loadView() {
      view = NSView()
    }

    func configure(item: MediaItem, thumbnail: MediaThumbnail?, isPreferredDuplicate: Bool) {
      let itemChanged = mediaItem != item
      let thumbnailChanged = self.thumbnail?.image.cgImage !== thumbnail?.image.cgImage
      guard
        hostingView == nil || itemChanged || thumbnailChanged
          || self.isPreferredDuplicate != isPreferredDuplicate
      else { return }
      self.isPreferredDuplicate = isPreferredDuplicate
      mediaItem = item
      self.thumbnail = thumbnail
      updateContent()
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      releaseImage()
      mediaItem = nil
    }

    func releaseImage() {
      guard thumbnail != nil else { return }
      thumbnail = nil
      updateContent()
      hostingView?.layoutSubtreeIfNeeded()
    }

    private func updateContent() {
      guard let mediaItem else { return }
      let content = MediaCell(
        item: mediaItem,
        thumbnail: thumbnail,
        isSelected: isSelected || highlightState == .forSelection,
        isPreferredDuplicate: isPreferredDuplicate
      )
      if let hostingView {
        hostingView.rootView = content
        return
      }

      let hostingView = NSHostingView(rootView: content)
      hostingView.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(hostingView)
      NSLayoutConstraint.activate([
        hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        hostingView.topAnchor.constraint(equalTo: view.topAnchor),
        hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
      self.hostingView = hostingView
    }
  }
#endif
