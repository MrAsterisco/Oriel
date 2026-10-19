import Foundation
import Testing

@testable import Oriel

struct PeopleCorpusValidationTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ORIEL_PEOPLE_CORPUS"] != nil,
      "Set ORIEL_PEOPLE_CORPUS to an explicitly prepared public validation corpus."))
  func publicPhotosGroupByTheirLabelledIdentity() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ORIEL_PEOPLE_CORPUS"])
    let url = URL(fileURLWithPath: path)
    let manifest = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: url.appending(path: "manifest.json")))
    let root = Folder(id: Folder.ID(), name: "Public Corpus", path: path, url: url)
    let repository = VisionFaceRecognitionRepository()
    var items: [MediaItem] = []
    var facesByID: [MediaItem.ID: [DetectedFace]] = [:]
    var detections: [String: [[Float]]] = [:]
    var missing: [String] = []
    var multiple: [String] = []
    var identities: [String: String] = [:]
    for sample in manifest.samples.sorted(by: { $0.relativePath < $1.relativePath }) {
      let item = MediaItem(
        id: .init(url: url.appending(path: sample.relativePath)), name: sample.relativePath,
        kind: .picture, dateAdded: nil, fileSize: nil, modificationDate: nil,
        relativePath: sample.relativePath)
      let faces = try await repository.faces(in: item)
      detections[sample.relativePath] = faces.map(\.embedding)
      if faces.isEmpty {
        missing.append(sample.relativePath)
        continue
      }
      if faces.count != 1 {
        multiple.append(sample.relativePath)
        continue
      }
      identities[sample.relativePath] = sample.identity
      items.append(item)
      facesByID[item.id] = faces
    }
    let expected = Set(manifest.samples.map(\.identity)).count
    var orders = [items, Array(items.reversed())]
    if !items.isEmpty {
      for offset in 1...8 {
        let split = (offset * 7) % items.count
        orders.append(Array(items[split...]) + Array(items[..<split]))
      }
    }
    var orderReports: [[String: Any]] = []
    for (orderIndex, order) in orders.enumerated() {
      var clusters: [PersonCluster] = []
      for item in order {
        try LocalPeopleRepository.add(facesByID[item.id] ?? [], in: item, root: root, to: &clusters)
      }
      try LocalPeopleRepository.mergeSplitGroups(&clusters)
      let groups = clusters.map { $0.group.items.map(\.relativePath) }
      let mixed = groups.filter { Set($0.compactMap { identities[$0] }).count > 1 }
      orderReports.append([
        "order": orderIndex, "actualGroups": groups.count,
        "groups": groups, "mixedIdentityGroups": mixed,
      ])
      #expect(mixed.isEmpty, "Scan order \(orderIndex) merged different labelled identities")
      #expect(groups.count == expected, "Scan order \(orderIndex) split a labelled identity")
      #expect(groups.flatMap { $0 }.count == identities.count)
    }
    let report: [String: Any] = [
      "sourceCommit": manifest.sourceCommit,
      "sampleCount": manifest.samples.count, "evaluatedPhotos": identities.count,
      "expectedPeople": expected, "orders": orderReports,
      "missingFaces": missing, "multipleFaces": multiple,
      "detections": detections, "identities": identities,
    ]
    let reportURL = FileManager.default.temporaryDirectory.appending(
      path: "oriel-people-public-validation.json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: reportURL)
    print("PUBLIC PEOPLE VALIDATION REPORT: \(reportURL.path)")
    #expect(identities.count > 0)
    #expect(missing.isEmpty)
    #expect(multiple.isEmpty)
  }

  private struct Manifest: Decodable {
    let sourceCommit: String
    let samples: [Sample]
  }

  private struct Sample: Decodable {
    let relativePath: String
    let identity: String
  }
}
