import Foundation

nonisolated struct DetectedFace: Sendable {
  let embedding: [Float]
  let thumbnail: MediaThumbnail
}

nonisolated struct PersonGroup: Identifiable, Sendable {
  let id: UUID
  let name: String
  let thumbnail: MediaThumbnail
  let items: [MediaItem]
  var mergedGroupIDs: Set<UUID> = []
}

nonisolated struct PersonCluster: Sendable {
  var group: PersonGroup
  var references: [MediaItem.ID: [Float]]
}
