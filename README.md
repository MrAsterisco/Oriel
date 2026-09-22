# Oriel

A fast, simple image and video viewer for folders on Apple platforms.

Oriel lets you open a folder, browse its pictures and videos, and view them without importing them into a library. It is being built as a native SwiftUI app, with access to user-selected folders handled through the platform's file-access APIs.

## Installation

Oriel is currently built from source. Clone this repository, open [Oriel.xcodeproj](Oriel/Oriel.xcodeproj) in Xcode, select the Oriel scheme, and run it on a supported Mac, iPhone, iPad, or Apple Vision Pro. There is no Swift package to add to another app.

## Usage

Choose **Open Folder** on the Welcome screen and select a folder containing pictures or videos. Oriel shows its folders in the sidebar and supported media in the main browser. Select an item to focus it, or activate it to open the picture or video viewer. Previously opened folders appear on the Welcome screen for quick access.

The [project plan](docs/PROJECT_PLAN.md) describes the intended feature set and behavior in detail; it is not a list of features guaranteed to be complete in the current build.

## Compatibility

The Xcode project targets macOS, iOS and iPadOS, and visionOS, with a minimum deployment target of 26.5 for each platform. You need a version of Xcode with the corresponding SDKs to build it.

## Architecture

Oriel follows a repository-backed, protocol-first dependency flow:

```text
SwiftUI view -> @MainActor @Observable feature model -> repository protocol -> system API or persistence
```

Factory constructs and injects the dependencies at app and feature boundaries. Views render state and forward user intent; repositories own external reads and writes. See the [architecture details](docs/PROJECT_PLAN.md#architecture) and [implementation rules](AGENTS.md) before changing a feature.

## Contributions

Contributions are welcome. Please open an issue to discuss substantial changes before starting work, then submit a pull request. Follow the architecture and repository conventions in [AGENTS.md](AGENTS.md).

## Status

Oriel is under active development. The [project plan](docs/PROJECT_PLAN.md) includes planned behavior alongside implemented work, so check the code and open issues for the current state.

## License

Oriel is distributed under the MIT license. See [LICENSE](LICENSE) for details.
