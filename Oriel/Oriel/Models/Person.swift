import CoreGraphics
import Foundation

nonisolated struct FaceThumbnailSource: Identifiable, Equatable, Sendable {
  nonisolated struct ID: Hashable, Sendable {
    let item: MediaItem
    let faceIndex: Int
  }

  let id: ID
  let transform: CGAffineTransform
}

nonisolated struct DetectedFace: Sendable {
  let embedding: [Float]
  let thumbnail: FaceThumbnailSource
}

nonisolated struct PersonGroup: Identifiable, Sendable {
  let id: UUID
  let name: String
  let thumbnail: FaceThumbnailSource
  var items: [MediaItem]
  var mergedGroupIDs: Set<UUID> = []
}

nonisolated struct PersonCluster: Sendable {
  var group: PersonGroup
  var references: [MediaItem.ID: [Float]]
}
