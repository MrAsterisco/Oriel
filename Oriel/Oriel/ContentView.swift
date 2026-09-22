import SwiftUI

struct ContentView: View {
  let model: any WelcomeFeatureModelProtocol

  #if os(macOS)
    let windowCoordinator: any ApplicationWindowCoordinatorProtocol
  #endif

  var body: some View {
    #if os(macOS)
      WelcomeFeatureView(model: model, windowCoordinator: windowCoordinator)
    #else
      WelcomeFeatureView(model: model)
    #endif
  }
}
