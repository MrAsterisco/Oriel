import Accelerate
import Foundation

nonisolated protocol PeopleRepository: Sendable {
  func thumbnail(for source: FaceThumbnailSource) async throws -> MediaThumbnail
  func people(in folder: Folder) async -> AsyncThrowingStream<[PersonGroup], any Error>
  func referenceFaces(at url: URL) async throws -> [DetectedFace]
  func pictures(matching face: DetectedFace, in folder: Folder) async
    -> AsyncThrowingStream<[MediaItem], any Error>
}

actor LocalPeopleRepository: PeopleRepository {
  private let media: any MediaRepository
  private let faces: any FaceRecognitionRepository
  private var cachedFaces: [MediaItem: [DetectedFace]] = [:]
  private var knownPeople: [Folder.ID: [PersonCluster]] = [:]
  private var scannedPictures: [Folder.ID: [MediaItem]] = [:]
  // Moderate matches need independent references; a confident reference can establish a new pose.
  private static let matchingSimilarity: Float = 0.363
  private static let confidentSimilarity: Float = 0.6

  init(media: any MediaRepository, faces: any FaceRecognitionRepository) {
    self.media = media
    self.faces = faces
  }

  func thumbnail(for source: FaceThumbnailSource) async throws -> MediaThumbnail {
    try await faces.thumbnail(for: source)
  }

  func people(in folder: Folder) -> AsyncThrowingStream<[PersonGroup], any Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task(priority: .background) {
        do {
          let pictures = try await media.recentMedia(in: folder)
            .filter { $0.kind == .picture }.sorted { $0.relativePath < $1.relativePath }
          try Task.checkCancellation()
          if scannedPictures[folder.id] == pictures, let clusters = knownPeople[folder.id] {
            continuation.yield(clusters.map(\.group))
            continuation.finish()
            return
          }
          let currentItems = Set(pictures)
          cachedFaces = cachedFaces.filter {
            !$0.key.id.url.pathComponents.starts(with: folder.url.pathComponents)
              || currentItems.contains($0.key)
          }
          var clusters = (knownPeople[folder.id] ?? []).map {
            PersonCluster(
              group: PersonGroup(
                id: $0.group.id, name: $0.group.name, thumbnail: $0.group.thumbnail, items: [],
                mergedGroupIDs: $0.group.mergedGroupIDs), references: $0.references)
          }
          continuation.yield([])
          var nextUpdate = ContinuousClock.now
          for item in pictures {
            try Task.checkCancellation()
            let detected = try await detectedFaces(in: item)
            try Self.add(detected, in: item, root: folder, to: &clusters)
            if !detected.isEmpty, ContinuousClock.now >= nextUpdate {
              continuation.yield(clusters.map(\.group).filter { !$0.items.isEmpty })
              nextUpdate = ContinuousClock.now.advanced(by: .milliseconds(250))
            }
          }
          try Task.checkCancellation()
          clusters.removeAll { $0.group.items.isEmpty }
          try Self.mergeSplitGroups(&clusters)
          knownPeople[folder.id] = clusters
          scannedPictures[folder.id] = pictures
          continuation.yield(clusters.map(\.group))
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func referenceFaces(at url: URL) async throws -> [DetectedFace] {
    let startedAccess = url.startAccessingSecurityScopedResource()
    defer { if startedAccess { url.stopAccessingSecurityScopedResource() } }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let item = MediaItem(
      id: .init(url: url), name: url.lastPathComponent, kind: .picture,
      dateAdded: nil, fileSize: values?.fileSize.map { Int64($0) },
      modificationDate: values?.contentModificationDate, relativePath: url.lastPathComponent)
    let detected = try await faces.faces(in: item)
    try Task.checkCancellation()
    guard !detected.isEmpty else { throw PeopleRepositoryError.noReferenceFace }
    return detected
  }

  func pictures(matching face: DetectedFace, in folder: Folder)
    -> AsyncThrowingStream<[MediaItem], any Error>
  {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task(priority: .background) {
        do {
          let reference = try Self.normalized(face.embedding)
          let pictures = try await media.recentMedia(in: folder)
            .filter { $0.kind == .picture }.sorted { $0.relativePath < $1.relativePath }
          var matches: [MediaItem] = []
          continuation.yield(matches)
          var nextUpdate = ContinuousClock.now
          for item in pictures {
            try Task.checkCancellation()
            let detected = try await detectedFaces(in: item)
            let isMatch = try detected.contains {
              let embedding = try Self.normalized($0.embedding)
              guard embedding.count == reference.count else {
                throw PeopleRepositoryError.invalidEmbedding
              }
              return Self.similarity(reference, embedding) >= Self.matchingSimilarity
            }
            if isMatch {
              matches.append(item)
              if ContinuousClock.now >= nextUpdate {
                continuation.yield(matches)
                nextUpdate = ContinuousClock.now.advanced(by: .milliseconds(250))
              }
            }
          }
          try Task.checkCancellation()
          continuation.yield(matches)
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func detectedFaces(in item: MediaItem) async throws -> [DetectedFace] {
    if let cached = cachedFaces[item] { return cached }
    let detected: [DetectedFace]
    do { detected = try await faces.faces(in: item) } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PeopleRepositoryError.analysisFailed(item.relativePath, error.localizedDescription)
    }
    try Task.checkCancellation()
    cachedFaces[item] = detected
    return detected
  }

  nonisolated private static func normalized(_ embedding: [Float]) throws -> [Float] {
    let magnitude = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
    guard magnitude.isFinite, magnitude > 0, !embedding.isEmpty else {
      throw PeopleRepositoryError.invalidEmbedding
    }
    return embedding.map { $0 / magnitude }
  }

  nonisolated static func add(
    _ faces: [DetectedFace], in item: MediaItem, root: Folder,
    to clusters: inout [PersonCluster]
  ) throws {
    var usedGroups = Set<Int>()
    for face in faces {
      try Task.checkCancellation()
      let embedding = try normalized(face.embedding)
      let reference = [item.id: embedding]
      let matches = try clusters.indices.compactMap { group -> (Int, Float)? in
        guard !usedGroups.contains(group), !clusters[group].references.isEmpty else { return nil }
        let evidence = try Self.referenceMatch(reference, clusters[group].references)
        // Defer an isolated moderate pair to the ordered reconciliation pass.
        let canAssign =
          evidence.supported
          && (evidence.score >= confidentSimilarity || clusters[group].references.count >= 2)
        return canAssign ? (group, evidence.score) : nil
      }
      if let match = matches.max(by: { $0.1 < $1.1 })?.0 {
        if clusters[match].group.items.isEmpty {
          let group = clusters[match].group
          clusters[match].group = PersonGroup(
            id: group.id, name: group.name, thumbnail: face.thumbnail, items: [],
            mergedGroupIDs: group.mergedGroupIDs)
        }
        if !clusters[match].group.items.contains(where: { $0.id == item.id }) {
          clusters[match].group.items.append(item)
        }
        // A rescan updates this face's reference instead of giving the same photo extra weight.
        clusters[match].references[item.id] = embedding
        usedGroups.insert(match)
      } else {
        let parent = item.id.url.deletingLastPathComponent().standardizedFileURL
        let name = parent == root.url.standardizedFileURL ? root.name : parent.lastPathComponent
        usedGroups.insert(clusters.count)
        clusters.append(
          PersonCluster(
            group: PersonGroup(
              id: UUID(), name: name,
              thumbnail: face.thumbnail, items: [item]), references: [item.id: embedding]))
      }
    }
    // Discard obsolete observations if an edited/replaced photo now has different faces.
    for index in clusters.indices where !usedGroups.contains(index) {
      clusters[index].references.removeValue(forKey: item.id)
    }
  }

  nonisolated static func mergeSplitGroups(_ clusters: inout [PersonCluster]) throws {
    var candidates: [(first: Int, second: Int, score: Float)] = []
    for first in clusters.indices {
      try Task.checkCancellation()
      for second in clusters.indices where second > first {
        let score = try referenceMatch(clusters[first].references, clusters[second].references)
          .score
        if score >= matchingSimilarity { candidates.append((first, second, score)) }
      }
    }
    candidates.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.first != $1.first { return $0.first < $1.first }
      return $0.second < $1.second
    }
    var parents = Array(clusters.indices)
    func survivor(_ index: Int) -> Int {
      var result = index
      while parents[result] != result { result = parents[result] }
      return result
    }
    var didMerge: Bool
    repeat {
      didMerge = false
      for candidate in candidates {
        try Task.checkCancellation()
        let roots = [survivor(candidate.first), survivor(candidate.second)].sorted()
        let first = roots[0]
        let second = roots[1]
        guard first != second else { continue }
        let photos = Set(clusters[first].references.keys)
        guard photos.isDisjoint(with: clusters[second].references.keys),
          try referenceMatch(clusters[first].references, clusters[second].references).supported
        else { continue }
        let kept = clusters[first].group
        let removed = clusters[second].group
        clusters[first].group = PersonGroup(
          id: kept.id, name: kept.name, thumbnail: kept.thumbnail,
          items: (kept.items + removed.items).sorted { $0.relativePath < $1.relativePath },
          mergedGroupIDs: kept.mergedGroupIDs.union(removed.mergedGroupIDs).union([removed.id]))
        clusters[first].references.merge(clusters[second].references) { first, _ in first }
        parents[second] = first
        didMerge = true
      }
    } while didMerge
    clusters = clusters.indices.filter { parents[$0] == $0 }.map { clusters[$0] }
  }

  nonisolated private static func referenceMatch(
    _ first: [MediaItem.ID: [Float]], _ second: [MediaItem.ID: [Float]]
  ) throws -> (score: Float, supported: Bool) {
    guard !first.isEmpty, !second.isEmpty else { return (-.infinity, false) }
    var best: Float = -.infinity
    var matchingFirst = Set<MediaItem.ID>()
    var matchingSecond = Set<MediaItem.ID>()
    for (firstID, firstEmbedding) in first {
      try Task.checkCancellation()
      for (secondID, secondEmbedding) in second {
        try Task.checkCancellation()
        let score = similarity(firstEmbedding, secondEmbedding)
        best = max(best, score)
        if score >= matchingSimilarity {
          matchingFirst.insert(firstID)
          matchingSecond.insert(secondID)
        }
      }
    }
    // Two singleton profiles bootstrap from one pair; larger profiles need corroboration on each side.
    let supported =
      best >= confidentSimilarity
      || (matchingFirst.count >= min(2, first.count)
        && matchingSecond.count >= min(2, second.count))
    return (best, supported)
  }

  nonisolated private static func similarity(_ first: [Float], _ second: [Float]) -> Float {
    guard !first.isEmpty, first.count == second.count else { return -.infinity }
    var result: Float = 0
    vDSP_dotpr(first, 1, second, 1, &result, vDSP_Length(first.count))
    return result
  }
}

nonisolated enum PeopleRepositoryError: LocalizedError {
  case analysisFailed(String, String)
  case invalidEmbedding
  case modelUnavailable
  case noReferenceFace

  var errorDescription: String? {
    switch self {
    case .analysisFailed(let name, let reason): "Couldn’t analyze faces in \(name): \(reason)"
    case .invalidEmbedding: "The face recognition model returned an invalid result."
    case .modelUnavailable: "The bundled face recognition model couldn’t be loaded."
    case .noReferenceFace: "No recognizable face was found. Choose a clearer photo of the person."
    }
  }
}
