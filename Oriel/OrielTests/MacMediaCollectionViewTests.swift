#if os(macOS)
  import AppKit
  import Testing

  @testable import Oriel

  @MainActor
  struct MacMediaCollectionViewTests {
    @Test
    func endingDisplayAndReuseReleaseHostedImages() async throws {
      let cell = MediaCollectionItem()
      let item = MediaItem(
        id: .init(url: URL(fileURLWithPath: "/photo.jpg")), name: "photo.jpg", kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: "photo.jpg")
      weak var released: CGImage?
      try autoreleasepool {
        let context = try #require(
          CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        released = image
        cell.configure(
          item: item, thumbnail: .init(image: .init(cgImage: image)), isPreferredDuplicate: false)
      }
      #expect(released != nil)
      let host = cell.view.subviews.first
      autoreleasepool { cell.releaseImage() }
      for _ in 0..<100 where released != nil {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(cell.view.subviews.first === host)
      #expect(released == nil)
      cell.configure(item: item, thumbnail: nil, isPreferredDuplicate: false)
      #expect(!cell.view.subviews.isEmpty)
      cell.prepareForReuse()
      #expect(cell.mediaItem == nil)
      #expect(cell.view.subviews.first === host)
    }

    @Test
    func thumbnailUpdatesVisitOnlyVisibleSectionHeaders() {
      let sections = (0..<10_000).map { index in
        MediaSection(
          id: .init(url: URL(fileURLWithPath: "/Folder/\(index)")), title: "Group \(index)",
          items: [])
      }
      let parent = MacMediaCollectionView(
        items: [], sections: sections, preferredDuplicateIDs: [], isCleaningDuplicates: false,
        showsDuplicateActions: true, onKeepBestCopy: { _ in }, itemsByID: [:], itemsRevision: 0,
        selectedMediaID: nil, isViewingAggregate: true, thumbnails: [:],
        capabilities: { _ in
          .init(canModify: false, canModifyContents: false, canMoveToTrash: false)
        },
        openingApplications: { _ in nil }, onSelect: { _ in }, onActivate: { _ in },
        onLoadThumbnail: { _ in }, onLoadOpeningApplications: { _ in },
        onDiscardThumbnail: { _ in }, onLoadCapabilities: { _ in },
        onMenuAction: { _, _ in }, onOpenWith: { _, _ in })
      let coordinator = parent.makeCoordinator()
      let collection = HeaderTrackingCollectionView()
      coordinator.updateVisibleItems(in: collection)
      #expect(collection.requestedHeaders == [IndexPath(item: 0, section: 5000)])
    }
  }

  @MainActor
  private final class HeaderTrackingCollectionView: NSCollectionView {
    var requestedHeaders: [IndexPath] = []

    override func indexPathsForVisibleSupplementaryElements(
      ofKind elementKind: NSCollectionView.SupplementaryElementKind
    )
      -> Set<IndexPath>
    {
      [IndexPath(item: 0, section: 5000)]
    }

    override func supplementaryView(
      forElementKind elementKind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath
    )
      -> (any NSView & NSCollectionViewElement)?
    {
      requestedHeaders.append(indexPath)
      return nil
    }
  }
#endif
