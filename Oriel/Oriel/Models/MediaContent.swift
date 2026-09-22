import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct MediaFolder: Identifiable, Hashable, Sendable {
  nonisolated struct ID: Hashable, Sendable {
    let url: URL
  }

  let id: ID
  let name: String
  let path: String
  let children: [MediaFolder]?
}

nonisolated enum MediaBrowserDestination: Hashable, Sendable {
  case recents
  case folder(MediaFolder.ID)
}

nonisolated enum MediaSortOption: CaseIterable, Hashable, Sendable {
  case mostRecent
  case name
  case size
}

nonisolated enum MediaSortDirection: Hashable, Sendable {
  case ascending
  case descending
}

nonisolated struct MediaSort: Hashable, Sendable {
  let option: MediaSortOption
  let direction: MediaSortDirection

  static let initial = MediaSort(option: .mostRecent, direction: .descending)
}

nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
  nonisolated enum Kind: Hashable, Sendable {
    case picture
    case video
  }

  nonisolated struct ID: Hashable, Sendable {
    let url: URL
  }

  let id: ID
  let name: String
  let kind: Kind
  let dateAdded: Date?
  let fileSize: Int64?
  let modificationDate: Date?
  let relativePath: String
}

nonisolated struct MediaTransferSource: Identifiable, Hashable, Sendable {
  let id: MediaItem.ID
  let kind: MediaItem.Kind?

  init(item: MediaItem) {
    id = item.id
    kind = item.kind
  }

  init(url: URL) {
    id = MediaItem.ID(url: url.standardizedFileURL)
    kind = nil
  }
}

extension MediaTransferSource: Transferable {
  nonisolated static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(
      exportedContentType: .image,
      shouldAllowToOpenInPlace: true
    ) { source in
      SentTransferredFile(source.id.url, allowAccessingOriginalFile: true)
    }
    .exportingCondition { $0.kind == .picture }

    FileRepresentation(
      exportedContentType: .movie,
      shouldAllowToOpenInPlace: true
    ) { source in
      SentTransferredFile(source.id.url, allowAccessingOriginalFile: true)
    }
    .exportingCondition { $0.kind == .video }

    ProxyRepresentation(
      exporting: { $0.id.url },
      importing: { MediaTransferSource(url: $0) }
    )
  }
}

nonisolated struct MediaTransferDestination: Hashable, Sendable {
  let folderID: MediaFolder.ID
}

nonisolated enum MediaTransferOperation: Hashable, Sendable {
  case copy
  case move
}

nonisolated struct MediaTransfer: Hashable, Sendable {
  let sources: [MediaTransferSource]
  let destination: MediaTransferDestination
  let operation: MediaTransferOperation
}

nonisolated struct MediaThumbnail: Sendable {
  let image: MediaImage
}

nonisolated struct PictureContent: Sendable {
  let item: MediaItem
  let image: MediaImage
  let pixelSize: MediaPixelSize

  init(item: MediaItem, image: MediaImage, pixelSize: MediaPixelSize? = nil) {
    self.item = item
    self.image = image
    self.pixelSize =
      pixelSize ?? MediaPixelSize(width: image.cgImage.width, height: image.cgImage.height)
  }
}

nonisolated struct MediaPixelSize: Equatable, Sendable {
  let width: Int
  let height: Int
}

nonisolated struct MediaNormalizedRect: Equatable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  static let full = MediaNormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

nonisolated struct MediaPixelRect: Equatable, Sendable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
}

nonisolated struct PictureCrop: Equatable, Sendable {
  let originalSize: MediaPixelSize
  let normalizedRect: MediaNormalizedRect

  var pixelRect: MediaPixelRect {
    let width = Double(originalSize.width)
    let height = Double(originalSize.height)
    let minX = Int((normalizedRect.x * width).rounded(.down))
    let minY = Int((normalizedRect.y * height).rounded(.down))
    let maxX = Int(((normalizedRect.x + normalizedRect.width) * width).rounded(.up))
    let maxY = Int(((normalizedRect.y + normalizedRect.height) * height).rounded(.up))
    return MediaPixelRect(
      x: minX,
      y: minY,
      width: max(maxX - minX, 1),
      height: max(maxY - minY, 1)
    )
  }
}

nonisolated enum MediaViewerMode: Equatable, Sendable {
  case crop(PictureCrop)
}

nonisolated enum OpenedMedia: Sendable {
  case picture(PictureContent)
  case video(MediaItem)

  var item: MediaItem {
    switch self {
    case .picture(let picture): picture.item
    case .video(let item): item
    }
  }
}

nonisolated struct MediaImage: Sendable {
  let cgImage: CGImage
}

nonisolated struct MediaBrowserSnapshot: Sendable {
  let folderTree: MediaFolder
  let selectedFolder: MediaFolder?
  let mediaItems: [MediaItem]
  let mediaItemsByID: [MediaItem.ID: MediaItem]

  init(
    folderTree: MediaFolder,
    selectedFolder: MediaFolder?,
    mediaItems: [MediaItem]
  ) {
    self.folderTree = folderTree
    self.selectedFolder = selectedFolder
    self.mediaItems = mediaItems
    mediaItemsByID = Dictionary(uniqueKeysWithValues: mediaItems.map { ($0.id, $0) })
  }
}
