# Oriel

A fast, simple image and video viewer for folders on Apple platforms.

Oriel lets you open a folder, browse its pictures and videos, and view them without importing them into a library. It is being built as a native SwiftUI app, with access to user-selected folders handled through the platform's file-access APIs.

## Installation

Oriel is currently built from source. Clone this repository, open [Oriel.xcodeproj](Oriel/Oriel.xcodeproj) in Xcode, select the Oriel scheme, and run it on a supported Mac, iPhone, iPad, or Apple Vision Pro. There is no Swift package to add to another app.

## Usage

Choose **Open Folder** on the Welcome screen and select a folder containing pictures or videos. Oriel shows its folders in the sidebar and supported media in the main browser. Select an item to focus it, or activate it to open the picture or video viewer. Previously opened folders appear on the Welcome screen for quick access.

Select several folders in the sidebar to browse their media in separate sections named after each folder (Command-click or Shift-click on Mac; use **Edit** on touch devices). Right-click a selected folder and choose **Merge Selected Folders** to move all contents, including hidden files and subfolders, into the selected folder that comes first alphabetically, then move the emptied folders to Trash. Existing names and conflicts between source folders stop the merge before any files move. Merging is available only for writable, separate folders below the current root and where recoverable Trash is supported. If a merge is interrupted, completed moves remain in place and the browser refreshes to show the actual contents.

Opening a folder starts a background scan for visually matching pictures across it and its subfolders. **Duplicates** in the sidebar shows the results and a badge counting matching groups. The badge stays visible when visiting other destinations or opening Duplicates, and disappears only when a successful scan finds no remaining groups. Matching runs on-device with Apple Vision, followed by strict pixel agreement checks to reject different shots of similar scenes. Groups appear as they are found, and the Duplicates screen shows a background-scanning indicator until the scan finishes. Each candidate group appears in its own section of the media browser, with the same selection, context-menu actions, and double-click viewer as ordinary media. Review candidates before removing them; visual similarity is not a guarantee of identical file contents. Use **Keep Best Copy** on a group to keep the highest-resolution image, then prefer greater bit depth, a known lossless format, and larger file size when those values tie. Other copies move to Trash; if recoverable Trash is unavailable, this shortcut leaves the group untouched. Groups refresh after file changes.

Opening a folder also starts a background **People** scan across its pictures and subfolders. People appears below Duplicates in the sidebar. Each face card opens that person’s photos in the normal browser and viewer; a photo with several people can appear in several albums. Matching uses multiple reference faces per person, and split entries are reconciled when the scan finishes. A person’s initial name comes from the containing folder of the first photo discovered, with photos scanned in relative-path order. Merging keeps the earlier-discovered name. Names stay stable during the session, even when earlier-sorting photos are added or the original photo is removed. Face detection, alignment, and recognition run entirely on-device using Apple Vision and a bundled SFace Core ML model. No photos or face embeddings are uploaded, and no model download is needed at runtime. Results are held in memory, refreshed after file changes, and rebuilt when the app restarts. Recognition can miss faces or group them incorrectly. See [People implementation and model provenance](docs/PEOPLE.md).

In **People**, choose **Search for person** and select a reference image to find matching photos throughout the opened folder and its subfolders. If the image contains several recognizable faces, choose the person to search for. Matches appear as they are found and use the normal media browser, file actions, and viewer. Search runs entirely on-device, reuses cached detections, and refreshes after file changes. Use **People** to leave the search or **Search for person** to choose another reference. Recognition can miss matches or include a different person.

The [project plan](docs/PROJECT_PLAN.md) describes the intended feature set and behavior in detail; it is not a list of features guaranteed to be complete in the current build.

Use **Show Duplicates** in a folder’s toolbar to show only duplicate groups with at least two matching pictures directly in that folder. This mode reuses the same background scan, keeps the sidebar selection, and stays enabled when switching folders. Turn it off to browse all media again; selecting Recents, Duplicates, or People also exits the mode.

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
