import Foundation

nonisolated struct Folder: Identifiable, Hashable, Sendable {
  nonisolated struct ID: Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
      self.rawValue = rawValue
    }
  }

  let id: ID
  let name: String
  let path: String
  let url: URL
}
