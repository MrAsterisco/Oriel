import CoreML
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Oriel

struct PeopleRepositoryTests {
  @Test
  func faceThumbnailCacheEvictsPixelsButKeepsSourcesUsable() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let first = testFaceThumbnailSource(at: url.appending(path: "first.png"))
    let second = testFaceThumbnailSource(at: url.appending(path: "second.png"))
    try writePicture(at: first.id.item.id.url)
    try writePicture(at: second.id.item.id.url)
    let repository = VisionFaceRecognitionRepository(thumbnailLimit: 1)
    weak var evicted: CGImage?
    do {
      let crop = try await repository.thumbnail(for: first)
      evicted = crop.image.cgImage
      #expect(crop.image.cgImage.width == 112)
      #expect(crop.image.cgImage.height == 112)
    }
    #expect(evicted != nil)
    _ = try await repository.thumbnail(for: second)
    #expect(evicted == nil)
    let reloaded = try await repository.thumbnail(for: first)
    #expect(reloaded.image.cgImage.width == 112)
  }

  @Test
  func strongIndividualReferenceIsNotDilutedByOtherPoses() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    for (index, degrees) in [0.0, 40, -40, 80].enumerated() {
      let angle = degrees * .pi / 180
      try LocalPeopleRepository.add(
        [face([Float(cos(angle)), Float(sin(angle))])],
        in: item("Alice/\(index).jpg", in: root), root: root, to: &clusters)
    }
    // The last face matches one reference at 0.766 even though its group-wide average is 0.147.
    #expect(clusters.count == 1)
    #expect(clusters[0].group.items.count == 4)
  }

  @Test
  func reconciliationUsesIndividualReferencesInsteadOfAveragingAwayAStrongMatch() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    for (index, degrees) in [0.0, 40, -40].enumerated() {
      let angle = degrees * .pi / 180
      try LocalPeopleRepository.add(
        [face([Float(cos(angle)), Float(sin(angle))])],
        in: item("Alice/\(index).jpg", in: root), root: root, to: &clusters)
    }
    let originalID = clusters[0].group.id
    var split: [PersonCluster] = []
    let angle = 80.0 * .pi / 180
    try LocalPeopleRepository.add(
      [face([Float(cos(angle)), Float(sin(angle))])],
      in: item("Holiday/portrait.jpg", in: root), root: root, to: &split)
    let retiredID = split[0].group.id
    clusters += split
    try LocalPeopleRepository.mergeSplitGroups(&clusters)
    #expect(clusters.count == 1)
    #expect(clusters[0].group.id == originalID)
    #expect(clusters[0].group.name == "Alice")
    #expect(clusters[0].group.mergedGroupIDs.contains(retiredID))
  }

  @Test
  func moderateEarlyPairDoesNotStealAPhotoBeforeItsStrongerReferenceArrives() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    let alice = item("Alice/01.jpg", in: root)
    let bob = item("Bob/02.jpg", in: root)
    let anotherBob = item("Holiday/03.jpg", in: root)
    try LocalPeopleRepository.add([face([1, 0, 0])], in: alice, root: root, to: &clusters)
    try LocalPeopleRepository.add([face([0.4, sqrt(0.84), 0])], in: bob, root: root, to: &clusters)
    #expect(clusters.count == 2)
    try LocalPeopleRepository.add(
      [face([0, 0.55, sqrt(1 - 0.55 * 0.55)])],
      in: anotherBob, root: root, to: &clusters)
    try LocalPeopleRepository.mergeSplitGroups(&clusters)
    #expect(clusters.count == 2)
    #expect(clusters[0].group.items == [alice])
    #expect(clusters[1].group.name == "Bob")
    #expect(clusters[1].group.items == [bob, anotherBob])
  }

  @Test
  func groupsAcrossFoldersKeepFirstNameAndSeparateFacesInTheSamePhoto() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    let first = item("Alice/01.jpg", in: root)
    let second = item("Holiday/02.jpg", in: root)
    let last = item("03.jpg", in: root)
    try LocalPeopleRepository.add(
      [face([1, 0]), face([0, 1])], in: first, root: root, to: &clusters)
    #expect(clusters.count == 2)
    #expect(clusters[0].group.id != clusters[1].group.id)
    #expect(clusters.map(\.group.name) == ["Alice", "Alice"])
    try LocalPeopleRepository.add([face([0.99, 0.01])], in: second, root: root, to: &clusters)
    try LocalPeopleRepository.add([face([-1, 0])], in: last, root: root, to: &clusters)
    try LocalPeopleRepository.mergeSplitGroups(&clusters)
    #expect(clusters.map(\.group.name) == ["Alice", "Alice", "Pictures"])
    #expect(clusters[0].group.items == [first, second])
    #expect(clusters[1].group.items == [first])
    #expect(clusters[2].group.items == [last])
  }

  @Test
  func matchesNewPosesUsingMultipleReferencesRatherThanOnlyTheFirstFace() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    for (index, vector) in [[Float(1), 0], [0.8, 0.6], [0.2, 0.98]].enumerated() {
      try LocalPeopleRepository.add(
        [face(vector)], in: item("Alice/\(index).jpg", in: root), root: root, to: &clusters)
    }
    #expect(clusters.count == 1)
    #expect(clusters[0].group.items.count == 3)
    #expect(clusters[0].references.count == 3)
    // The last face has similarity 0.2 to the first, below even SFace's upstream cutoff.
  }

  @Test
  func mergesSplitEntriesWhenLaterReferencesAgreeAndKeepsTheFirstPhotoName() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    let first = item("Alice/01.jpg", in: root)
    let second = item("Holiday/02.jpg", in: root)
    let bridge = item("Vacation/03.jpg", in: root)
    try LocalPeopleRepository.add([face([1, 0])], in: first, root: root, to: &clusters)
    let originalID = clusters[0].group.id
    try LocalPeopleRepository.add([face([0.1, 0.995])], in: second, root: root, to: &clusters)
    #expect(clusters.count == 2)
    let splitID = clusters[1].group.id
    try LocalPeopleRepository.add([face([0.8, 0.6])], in: bridge, root: root, to: &clusters)
    try LocalPeopleRepository.mergeSplitGroups(&clusters)
    #expect(clusters.count == 1)
    #expect(clusters[0].group.id == originalID)
    #expect(clusters[0].group.name == "Alice")
    #expect(clusters[0].group.items == [first, second, bridge])
    #expect(clusters[0].group.mergedGroupIDs == [splitID])
    #expect(clusters[0].references.count == 3)
    // Repeated scans must not overweight the same photo and shift the identity profile.
    for _ in 0..<3 {
      try LocalPeopleRepository.add([face([0.8, 0.6])], in: bridge, root: root, to: &clusters)
    }
    #expect(clusters[0].references.count == 3)
    #expect(clusters[0].group.items.count == 3)
  }

  @Test
  func similarFacesInTheSamePhotoCannotBeMergedEvenAfterAnotherMatchingPhoto() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    try LocalPeopleRepository.add(
      [face([1, 0]), face([0.99, 0.1])],
      in: item("Alice/together.jpg", in: root), root: root, to: &clusters)
    try LocalPeopleRepository.add(
      [face([1, 0])],
      in: item("Holiday/solo.jpg", in: root), root: root, to: &clusters)
    try LocalPeopleRepository.mergeSplitGroups(&clusters)
    #expect(clusters.count == 2)
    #expect(clusters.map { $0.group.items.count } == [2, 1])
  }

  @Test
  func refusesInvalidEmbeddingsAndDoesNotMergeThroughAWeakChain() throws {
    let root = folder()
    var clusters: [PersonCluster] = []
    // Neighboring faces match, but the two ends disagree: one bridge must not merge them all.
    for (index, vector) in [[Float(1), 0], [0.5, 0.866], [-0.5, 0.866]].enumerated() {
      try LocalPeopleRepository.add(
        [face(vector)], in: item("\(index).jpg", in: root), root: root, to: &clusters)
    }
    try LocalPeopleRepository.mergeSplitGroups(&clusters)
    #expect(clusters.map { $0.group.items.count } == [2, 1])
    for vector: [Float] in [[], [0, 0], [.nan, 1], [.infinity, 0]] {
      #expect(throws: (any Error).self) {
        try LocalPeopleRepository.add(
          [face(vector)], in: item("bad.jpg", in: root), root: root, to: &clusters)
      }
    }
  }

  @Test
  func recursiveScanCachesFacesAndDropsDeletedPictures() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: url.appending(path: "Alice"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: url.appending(path: "Holiday"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let root = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let firstURL = url.appending(path: "Alice/01.png")
    let secondURL = url.appending(path: "Holiday/02.png")
    try writePicture(at: firstURL)
    try writePicture(at: secondURL)
    try Data().write(to: url.appending(path: "clip.mov"))
    let faces = CountingFaceRepository(face: face([1, 0]))
    let repository = LocalPeopleRepository(media: LocalMediaRepository(), faces: faces)
    var groups: [PersonGroup] = []
    for try await update in await repository.people(in: root) { groups = update }
    #expect(groups.count == 1)
    #expect(groups[0].name == "Alice")
    #expect(groups[0].items.map(\.relativePath) == ["Alice/01.png", "Holiday/02.png"])
    #expect(await faces.readCount == 2)
    var cachedUpdates = 0
    for try await update in await repository.people(in: root) {
      groups = update
      cachedUpdates += 1
    }
    #expect(cachedUpdates == 1)
    #expect(await faces.readCount == 2)
    try FileManager.default.removeItem(at: secondURL)
    for try await update in await repository.people(in: root) { groups = update }
    #expect(groups[0].items.map(\.relativePath) == ["Alice/01.png"])
    // Replacing a picture invalidates its cached recognition, including cached no-face results.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: firstURL.path)
    for try await _ in await repository.people(in: root) {}
    #expect(await faces.readCount == 3)
    let earlier = url.appending(path: "Aardvark/03.png")
    try FileManager.default.createDirectory(
      at: earlier.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePicture(at: earlier)
    for try await update in await repository.people(in: root) { groups = update }
    #expect(groups.count == 1)
    #expect(groups[0].name == "Alice")
    let identity = groups[0].id
    try FileManager.default.removeItem(at: firstURL)
    for try await update in await repository.people(in: root) { groups = update }
    #expect(groups[0].id == identity)
    #expect(groups[0].name == "Alice")
    #expect(groups[0].items.map(\.relativePath) == ["Aardvark/03.png"])
    #expect(groups[0].thumbnail.id.item.id.url == earlier)
  }

  @Test
  func backgroundScansReconcilePreviouslySplitPeopleAndKeepTheFirstDiscoveredName() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let paths = ["Alice/01.png", "Holiday/02.png", "Vacation/03.png"]
    for path in paths {
      try FileManager.default.createDirectory(
        at: url.appending(path: path).deletingLastPathComponent(),
        withIntermediateDirectories: true)
    }
    let root = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let items = paths.map { item($0, in: root) }
    let faces = FixtureFaceRepository(facesByID: [
      items[0].id: [face([1, 0])], items[1].id: [face([0.1, 0.995])],
      items[2].id: [face([0.8, 0.6])],
    ])
    let repository = LocalPeopleRepository(media: LocalMediaRepository(), faces: faces)
    try writePicture(at: items[0].id.url)
    try writePicture(at: items[1].id.url)
    var groups: [PersonGroup] = []
    for try await update in await repository.people(in: root) { groups = update }
    #expect(groups.count == 2)
    let firstID = groups[0].id
    let splitID = groups[1].id
    try writePicture(at: items[2].id.url)
    for try await update in await repository.people(in: root) { groups = update }
    #expect(groups.count == 1)
    #expect(groups[0].id == firstID)
    #expect(groups[0].name == "Alice")
    #expect(groups[0].items.map(\.relativePath) == paths)
    #expect(groups[0].mergedGroupIDs.contains(splitID))
    // Another rescan must keep both the merged identity and each photo exactly once.
    for try await update in await repository.people(in: root) { groups = update }
    #expect(groups.count == 1)
    #expect(groups[0].id == firstID)
    #expect(groups[0].items.map(\.relativePath) == paths)
  }

  @Test
  func alignmentMapsRotatedScaledLandmarksAndRejectsDegenerateInput() throws {
    let source = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
    let expected = CGAffineTransform(a: 0, b: 2, c: -2, d: 0, tx: 12, ty: 17)
    let target = source.map { $0.applying(expected) }
    let transform = try #require(
      VisionFaceRecognitionRepository.alignmentTransform(from: source, to: target))
    for (actual, expected) in zip(source.map { $0.applying(transform) }, target) {
      #expect(abs(actual.x - expected.x) < 0.00001)
      #expect(abs(actual.y - expected.y) < 0.00001)
    }
    #expect(
      VisionFaceRecognitionRepository.alignmentTransform(from: [.zero, .zero], to: [.zero, .zero])
        == nil)
  }

  @Test
  func personSearchMatchesEveryPictureDirectlyAndRefreshesChangedAndDeletedFiles() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let root = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let paths = ["01.png", "Nested/02.png", "Nested/03.png", "Other/04.png"]
    let items = paths.map { item($0, in: root) }
    for item in items {
      try FileManager.default.createDirectory(
        at: item.id.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try writePicture(at: item.id.url)
    }
    try Data().write(to: url.appending(path: "clip.mov"))
    let faces = FixtureFaceRepository(facesByID: [
      items[0].id: [face([10, 0])],
      items[1].id: [face([0, 1]), face([0.8, 0.6]), face([1, 0])],
      items[2].id: [face([0.4, sqrt(0.84)])],
      items[3].id: [face([0, 1])],
    ])
    let repository = LocalPeopleRepository(media: LocalMediaRepository(), faces: faces)
    var matches: [MediaItem] = []
    for try await update in await repository.pictures(matching: face([2, 0]), in: root) {
      matches = update
    }
    #expect(matches.map(\.relativePath) == Array(paths.prefix(3)))
    // Search uses individual faces, including a moderate match without an album or corroboration.
    try FileManager.default.removeItem(at: items[0].id.url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: items[1].id.url.path)
    for try await update in await repository.pictures(matching: face([0, 5]), in: root) {
      matches = update
    }
    #expect(matches.map(\.relativePath) == Array(paths.dropFirst()))
    for try await update in await repository.pictures(matching: face([-1, 0]), in: root) {
      matches = update
    }
    #expect(matches.isEmpty)
  }

  @Test
  func personSearchSharesCachedDetectionsAndRejectsInvalidReferenceEmbeddings() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let root = Folder(id: Folder.ID(), name: "Pictures", path: url.path, url: url)
    let picture = url.appending(path: "photo.png")
    try writePicture(at: picture)
    let faces = CountingFaceRepository(face: face([1, 0]))
    let repository = LocalPeopleRepository(media: LocalMediaRepository(), faces: faces)
    for try await _ in await repository.people(in: root) {}
    for try await _ in await repository.pictures(matching: face([1, 0]), in: root) {}
    #expect(await faces.readCount == 1)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: picture.path)
    for try await _ in await repository.pictures(matching: face([1, 0]), in: root) {}
    #expect(await faces.readCount == 2)
    for vector: [Float] in [[], [0, 0], [.nan, 1], [.infinity, 0], [1, 0, 0]] {
      await #expect(throws: PeopleRepositoryError.self) {
        for try await _ in await repository.pictures(matching: face(vector), in: root) {}
      }
    }
  }

  @Test
  func referenceImageReturnsAllFacesAndReportsNoFaceAndUnreadableImages() async throws {
    let url = URL(fileURLWithPath: "/Reference/group.png")
    let reference = MediaItem.ID(url: url)
    let repository = LocalPeopleRepository(
      media: LocalMediaRepository(),
      faces: FixtureFaceRepository(facesByID: [reference: [face([1, 0]), face([0, 1])]]))
    #expect(try await repository.referenceFaces(at: url).map(\.embedding) == [[1, 0], [0, 1]])
    await #expect(throws: PeopleRepositoryError.self) {
      try await repository.referenceFaces(at: url.appendingPathExtension("missing"))
    }
    let live = LocalPeopleRepository(
      media: LocalMediaRepository(), faces: VisionFaceRecognitionRepository())
    await #expect(throws: MediaRepositoryError.self) {
      try await live.referenceFaces(at: url)
    }
  }

  @Test
  func bundledModelProducesFiniteIdentityEmbeddings() throws {
    let url = try #require(Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc"))
    let model = try MLModel(contentsOf: url)
    let input = try MLFeatureValue(
      cgImage: thumbnail().image.cgImage,
      pixelsWide: 112, pixelsHigh: 112, pixelFormatType: kCVPixelFormatType_32BGRA, options: [:])
    let output = try model.prediction(
      from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
    let embedding = try #require(output.featureValue(for: "embedding")?.multiArrayValue)
    #expect(embedding.count == 128)
    #expect((0..<128).allSatisfy { embedding[$0].floatValue.isFinite })
    #expect((0..<128).contains { embedding[$0].floatValue != 0 })
  }

  private func folder() -> Folder {
    Folder(
      id: Folder.ID(), name: "Pictures", path: "/Pictures", url: URL(fileURLWithPath: "/Pictures"))
  }

  private func item(_ path: String, in root: Folder) -> MediaItem {
    MediaItem(
      id: .init(url: root.url.appending(path: path)),
      name: URL(fileURLWithPath: path).lastPathComponent,
      kind: .picture, dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: path)
  }

  private func thumbnail() -> MediaThumbnail {
    let context = CGContext(
      data: nil, width: 112, height: 112, bitsPerComponent: 8,
      bytesPerRow: 448, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
    return MediaThumbnail(image: MediaImage(cgImage: context.makeImage()!))
  }

  private func face(_ embedding: [Float]) -> DetectedFace {
    DetectedFace(embedding: embedding, thumbnail: testFaceThumbnailSource())
  }

  private func writePicture(at url: URL) throws {
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, thumbnail().image.cgImage, nil)
    #expect(CGImageDestinationFinalize(destination))
  }
}

private actor CountingFaceRepository: FaceRecognitionRepository {
  let face: DetectedFace
  private(set) var readCount = 0
  init(face: DetectedFace) { self.face = face }
  func thumbnail(for source: FaceThumbnailSource) async throws -> MediaThumbnail {
    throw MediaRepositoryError.thumbnailUnavailable
  }
  func faces(in item: MediaItem) async throws -> [DetectedFace] {
    readCount += 1
    return [
      DetectedFace(
        embedding: face.embedding,
        thumbnail: FaceThumbnailSource(
          id: .init(item: item, faceIndex: 0), transform: face.thumbnail.transform))
    ]
  }
}

private struct FixtureFaceRepository: FaceRecognitionRepository {
  let facesByID: [MediaItem.ID: [DetectedFace]]
  func thumbnail(for source: FaceThumbnailSource) async throws -> MediaThumbnail {
    throw MediaRepositoryError.thumbnailUnavailable
  }
  func faces(in item: MediaItem) async throws -> [DetectedFace] { facesByID[item.id] ?? [] }
}

nonisolated func testFaceThumbnailSource(at url: URL = URL(fileURLWithPath: "/Pictures/face.png"))
  -> FaceThumbnailSource
{
  FaceThumbnailSource(
    id: .init(
      item: MediaItem(
        id: .init(url: url), name: url.lastPathComponent, kind: .picture,
        dateAdded: nil, fileSize: nil, modificationDate: nil, relativePath: url.lastPathComponent),
      faceIndex: 0), transform: .identity)
}
