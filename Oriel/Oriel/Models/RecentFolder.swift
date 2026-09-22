import Foundation

nonisolated struct RecentFolder: Identifiable, Hashable, Sendable {
  nonisolated enum Availability: Hashable, Sendable {
    case available
    case unavailable
  }

  let id: Folder.ID
  let name: String
  let path: String
  let availability: Availability
}
