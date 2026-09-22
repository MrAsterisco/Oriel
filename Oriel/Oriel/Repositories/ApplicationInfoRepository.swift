import Foundation

nonisolated protocol ApplicationInfoRepository: Sendable {
  var version: String { get }
}

nonisolated struct BundleApplicationInfoRepository: ApplicationInfoRepository {
  private let bundle: Bundle

  init(bundle: Bundle = .main) {
    self.bundle = bundle
  }

  var version: String {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
  }
}
