# Oriel

Oriel is a multi-platform SwiftUI app for browsing pictures and videos stored in a folder chosen by the user. The chosen location may be a regular folder, an entire volume, or a folder on a network volume or share, subject to the access provided by each platform.

## Feature list

### Choose a media folder

- Start on a Welcome screen inspired by Xcode's welcome window.
- Show Oriel's app icon, app name, and current app version.
- Provide one primary **Open Folder** button.
- Open the platform's system folder picker from the button.
- Allow any folder exposed by the picker, including mounted volumes and network locations.
- Keep the Welcome screen open if the user cancels the picker.
- Replace the Welcome screen with the media browser after a folder is opened successfully.

#### Recent folders

- Show previously opened folders in a recent-folders list on the Welcome screen.
- Display each folder's name and path so similarly named locations can be distinguished.
- Order the list with the most recently opened folder first and avoid duplicate entries.
- Open a recent folder when its row is activated and move it to the top of the list.
- Remember the list between app launches.
- Track a folder by the platform's persistent file reference rather than by a stored path, so the recent entry follows the folder when it is moved or renamed.
- Resolve every recent entry to its current name and path before displaying it, and refresh stale persistent references.
- Remove a recent entry and its stored authorization when the folder is confirmed to have been deleted.
- Do not treat a disconnected network share, unmounted removable volume, unavailable file provider, or lost permission as deletion; keep that entry so it can recover or be located again.
- If a recent folder is unavailable or Oriel no longer has permission to access it, remain on the Welcome screen and ask the user to locate it again.

##### macOS recents

- Use the system-managed, per-application recent-items list exposed by `NSDocumentController`; do not persist a parallel Oriel recents list or ordering.
- Use the same system list for the Welcome screen and the standard **File > Open Recent** menu.
- Record an opened folder with `noteNewRecentDocumentURL(_:)` and read the Welcome list from `recentDocumentURLs`.
- Honor the system's maximum recent-item count and provide its standard clear-all behavior. Individual removal is not required because AppKit exposes clearing the list, not removing one entry.
- Let the system recent-items mechanism track moved or renamed folders, then resolve the corresponding authorization bookmark before displaying or opening one.
- When a folder is confirmed deleted, remove it from the system list. Because AppKit has no public remove-one operation, rebuild the system list from the surviving entries without creating a separate recents store.
- Route selections from the system Open Recent menu into Oriel's folder-window flow.

##### iPadOS and iOS recents

- Persist Oriel's own recent-folders list because the system folder picker doesn't expose its recents to the Welcome screen. Store a reference to the folder's bookmark identity, not an absolute path as its identity.
- Continue using the system folder picker for selection; without an explicit starting location, it opens at the last directory the user chose.
- Do not use `UIDocumentBrowserViewController` for recents because it is document-oriented and doesn't support selecting the folder content type.

##### Persistent folder access

- Treat recency and permission as separate concerns on every platform.
- Persist and resolve the platform bookmark required to reopen a sandboxed folder independently of the recent-folders list.
- Use resolved bookmark URLs as the current folder location; bookmarks normally follow a folder across moves and renames.
- Replace a stored bookmark when resolution reports that it is stale.
- Never assume that a URL appearing in recents still grants access; request the folder again when authorization restoration fails.

### Open folders in windows and tabs

- Open each folder in its own browser window so multiple folders can be browsed independently.
- Keep one root folder and its browsing state per window.

#### macOS

- Dismiss the Welcome window automatically after a folder opens.
- Allow the Welcome window to be shown again from the **Window** menu.
- Support standard macOS window tabs, with a different folder open in each tab.
- Open a folder selected from **File > Open Recent** in its own folder window or tab.

#### iPadOS

- Start every newly created app window on the Welcome screen.
- Open the folder chosen from that Welcome screen in the same window.
- Allow additional folders to be opened by creating additional app windows.

### Browse folders

- Show the selected folder in a split navigation view.
- Open the folder window immediately, then load its directory tree and initial media destination asynchronously.
- Display its nested folder structure in the sidebar.
- Allow folders to be expanded, collapsed, and selected.
- Keep the sidebar visible while browsing or viewing media.

### Browse recent media

- Show a **Recents** destination at the top of the sidebar navigation, above the selected folder's directory tree.
- Keep this media destination distinct from the recent-folders list on the Welcome screen.
- Scope Recents to the root folder owned by the current window or tab.
- Recursively include every supported picture and video in that root folder and all of its descendant folders.
- Show the resulting items in the same main media browser used for a selected folder, with the most recently added item first.
- Use the file's `addedToDirectoryDate` as its date-added value. If the volume doesn't provide it, fall back to its creation date and then its content-modification date.
- Put items with no supported timestamp after dated items. Use their relative paths as a deterministic tie-breaker instead of inventing a date.
- Do not impose an arbitrary age cutoff or item limit; Recents represents all supported media under the selected root, ordered by date added.
- Refresh the result when Recents is selected and when Oriel learns that the root folder's contents changed.
- Remove files from the result when they are deleted or become unsupported.
- Open an item with the existing picture or video viewer. Keyboard navigation and looping operate over the current Recents ordering.

### Browse media

- Show the pictures and videos directly contained in the selected folder in the main content view.
- Use visual thumbnails so files are easy to identify.
- Ignore unsupported and unrelated files.
- Represent loading, empty folders, inaccessible folders, and read errors clearly.
- Show a **Sort** menu on the right side of the window toolbar while viewing a folder.
- Sort folder media by **Most Recent**, **Name**, or **Size**. The active option can be ascending or descending; selecting another option turns the previous one off so exactly one option is always active.
- Default folder sorting to **Most Recent**, descending. Keep the recursive Recents destination fixed to newest first.
- Apply media sorting in `MediaRepository`, not in a view or feature model.

### Select media

- Select and visibly highlight a picture or video with one primary click, or one tap on touch platforms, without opening it.
- Keep selection to one media item at a time. Selecting another item replaces the current selection, and activating empty space clears it.
- Apply the same selection behavior in normal folder results and recursive Recents results.
- Preserve the selected file when sorting or refreshing changes its position by tracking its stable media identity. Clear selection when that identity is no longer in the current result.
- Double-clicking or otherwise activating an item selects it and opens it in the viewer.
- Starting a drag from an unselected media item selects that item before beginning the drag.
- Render selection with the platform's standard active and inactive appearance and expose the selected state to accessibility technologies.

### Drag and drop media

- Treat every writable folder as a drop destination in both places where it appears: its sidebar row and the main media area while that folder is selected.
- Accept supported pictures and videos dragged from Oriel, Finder, Files, and other apps that provide compatible file URLs.
- Allow media items to be dragged out of both normal folder results and recursive Recents results into another Oriel folder, Finder, Files, or another compatible app.
- Reuse the platform's native drag operation negotiation. Honor whether the current operation is copy or move, including modifier-key changes on macOS, rather than inferring an operation from file paths.
- Do not accept drops on the aggregate **Recents** destination because it doesn't identify one physical folder. Its media items remain valid drag sources.
- Highlight a valid destination during the drag and reject unsupported media, read-only folders, and inaccessible destinations without changing any files.
- Never overwrite an existing file silently. Report a name conflict and leave both the source and destination unchanged until the user chooses how to resolve it.
- Treat a drop into the file's existing parent folder as a no-op.
- Refresh the affected folder results, directory tree, and recursive Recents results after a successful copy or move.
- If a move crosses volumes or providers, remove the source only after the copy has completed successfully. Surface partial failures without deleting the original.

### Manage files with context menus

- Show context menus with secondary click or Control-click on pointer platforms and long press on touch platforms. Opening an item's context menu selects that item first.
- Keep menus short, use no more than three action groups, hide actions that don't apply, and place destructive actions last with the platform's destructive styling.
- Provide the same media-item commands in a normal folder, in recursive Recents, and in the media viewer when they apply.

#### Media-item menu

1. **Open**, **Open With…** on macOS, and **Share…**.
2. **Rename…**, **Duplicate**, **Copy**, **Move To…**, **Reveal in Folder** when viewing Recents, **Show in Finder** on macOS or **Show in Files** where the platform supports it, and **Get Info**.
3. **Move to Trash** when the location provides recoverable trash semantics; otherwise show **Delete…** and require confirmation before permanent deletion.

- **Rename…** changes the base name while preserving the file extension. Reject invalid names and unresolved conflicts without changing the file.
- **Duplicate** creates a sibling using the platform's conventional unique-copy name.
- **Copy** places a transferable file reference on the system clipboard. **Paste** into a writable folder copies it there.
- **Move To…** opens the platform folder picker, requests access to the chosen destination for that operation, and uses the same safe move behavior as drag and drop.
- **Reveal in Folder** switches from Recents or its media viewer to the item’s containing folder and keeps the item selected.
- **Get Info** shows Oriel's available filename, kind, size, dates, dimensions, duration, and current location without modifying the file.
- When invoked from Recents, every command operates on the item's real current location and refreshes both its parent folder and Recents after a mutation.

#### Folder and background menus

- A sidebar folder provides **Open**, **Open in New Window**, **Open in New Tab** on macOS, **New Folder**, and **Paste**, followed by the applicable **Rename…**, **Duplicate**, **Copy**, **Move To…**, **Share…**, reveal, and **Get Info** commands. Put **Move to Trash** or confirmed **Delete…** last for non-root folders.
- The selected root folder is the window or tab's access anchor. Do not offer **Rename…**, **Duplicate**, **Move To…**, **Move to Trash**, or **Delete…** for it inside Oriel.
- The empty area of a selected physical folder provides **New Folder**, **Paste**, reveal, and **Get Info** for that folder.
- The aggregate Recents destination has no folder menu because it doesn't represent one physical location.
- Confirm deletion of a nonempty folder and clearly state that all of its contents are affected.
- Refresh the folder tree, current media result, Recents, and selection after every successful mutation.

#### Menu availability

- Hide mutation commands when Oriel lacks write access, the provider doesn't support the operation, or the target no longer exists. Don't present a command that can only fail.
- Make the same commands discoverable outside the context menu through the applicable macOS menu-bar commands or platform toolbar actions.
- Defer compression, tags, aliases, file locking, and media-content editing; they aren't part of Oriel's core browsing and file-organization workflow.

### View pictures

- Open a picture so it fills the main content pane when it is double-clicked, without entering app-level full screen.
- Preserve the sidebar and current folder selection while the picture is open.
- Provide an obvious way to return to the folder's media browser.
- Use the equivalent primary activation gesture on platforms without double-click input.

### View videos

- Open and play a selected video in the main content view.
- Provide the platform's standard playback controls.
- Preserve the sidebar and current folder selection during playback.

### Navigate media with a keyboard

- Support hardware-keyboard navigation on every platform.
- Use the left and up arrow keys to open the previous supported media file, and the right and down arrow keys to open the next one.
- Follow the same file order shown in the selected folder's media browser.
- Loop through the sequence: moving forward from the last file opens the first file, and moving backward from the first file opens the last file.
- Keep the navigation keys active while a video is open, with the same behavior used for pictures.
- Use the Space bar to play or pause the open video.

### Zoom and pan media

- Allow opened pictures and videos to be zoomed in and out without changing their aspect ratio.
- Allow zoomed media to be panned within the main content pane.
- Support mouse users with accessible zoom controls and click-drag panning.
- Support trackpads with pinch-to-zoom and pan gestures.
- Support touch screens with pinch-to-zoom and drag-to-pan gestures.

### Crop pictures

- Show a **Crop** action in the picture viewer toolbar. Videos don't enter picture-editing modes.
- Enter a distinct viewer mode with a movable crop selection, four draggable corner handles, a rule-of-thirds grid, a dimmed area outside the selection, and the resulting pixel dimensions.
- Show a bottom mode banner that identifies Crop mode and offers **Cancel**, **Save a Copy**, and **Save**.
- Cancel and Escape leave the source file unchanged. Save replaces it; Save a Copy writes a conventionally named sibling and leaves the source unchanged. Preserve writable source formats, and convert other single-frame pictures to PNG. Reject multi-frame pictures rather than silently discarding frames.
- Keep viewer-mode state and transitions in the media-browser feature model. Views render the active mode and forward intent, while the file-operation repository owns image encoding and file writes.

### Work across Apple platforms

- Support macOS, iPhone, iPad, and Apple Vision Pro from the shared SwiftUI project.
- Adapt folder selection, navigation, activation gestures, and layout to each platform while keeping the same browsing model.
- Respect platform sandboxing and retain access to user-selected locations only through supported system mechanisms.

## Architecture

Oriel uses a repository-backed, protocol-first architecture with SwiftUI's native Observation data flow. Apple does not prescribe MVC, MVVM, VIPER, or another single architecture for SwiftUI; it recommends choosing an architecture that fits the app and using SwiftUI's data-flow tools correctly. Oriel therefore uses feature models rather than adding a separate view-model convention on top of SwiftUI.

```text
SwiftUI view
    | user intent / observed state
    v
@MainActor @Observable feature model
    | protocol dependency
    v
Repository protocol
    | maps system data to Oriel models
    v
Foundation and platform frameworks / persistence

Factory composes and injects the graph at its boundaries.
```

### Swift models

- Represent folders, recent folders, media items, and other app data with Oriel-owned Swift value models such as `Folder`, `RecentFolder`, and `MediaItem`.
- Models wrap the underlying system content and provide the stable identity and metadata the app needs.
- Models contain data only. They do not read files, persist state, resolve dependencies, or perform presentation logic.
- Repositories return Oriel models instead of exposing raw persistence records, bookmark data, file enumerators, or media-framework objects.
- Make models `Sendable` when they cross an isolation boundary and add conformances such as `Identifiable`, `Hashable`, or `Codable` only when the feature requires them.

### Repository layer

- Put every operation that reads or writes external data behind a repository protocol. This includes the file system, recent-folder sources, persistent folder authorization, media metadata, and thumbnails.
- Define `RecentsFolderRepository` as the boundary for listing, recording, and clearing recent folders. It owns recency only, not permission to access those folders.
- Define `FolderAccessRepository` as the separate boundary for creating, persisting, resolving, refreshing, starting, and stopping bookmark-backed access to user-selected folders.
- Make `RecentsFolderRepository` collaborate with `FolderAccessRepository` when listing entries so it returns current, validated `RecentFolder` models and prunes confirmed deletions before they reach the UI.
- Define `MediaRepository` as the boundary for both direct-folder media queries and the recursive recent-media query. Views and feature models must not enumerate the file system or derive file dates.
- Define `FileOperationRepository` as the single mutation boundary for file management and picture writes: create folders, rename, duplicate, copy, move, paste, crop pictures, move to trash, and permanently delete when trash isn't available. It also loads the metadata required by **Get Info**.
- Views only connect SwiftUI's context-menu, drag-and-drop, sharing, and system-presentation APIs to feature-model intent and state. They never inspect, copy, move, rename, delete, or coordinate files directly.
- Represent a transfer with Oriel-owned source, destination, and operation values. Keep raw item-provider and file-coordination objects inside the repository implementation.
- Honor the copy or move operation negotiated by the platform. Reject unsupported sources, inaccessible or read-only destinations, same-folder transfers, and unresolved name conflicts before mutating the file system.
- For a cross-volume or cross-provider move, complete and validate the destination copy before deleting the source. Never silently overwrite a destination or delete a source after a failed or cancelled copy.
- Use `FolderAccessRepository` to acquire and scope access when **Move To…** or another command selects a destination outside the current root. Don't persist that destination unless the user separately opens it as a root folder.
- Return Oriel-owned operation results and file-info models. Keep pasteboard objects, security-scoped access tokens, file coordinators, and platform workspace objects behind repository or system-presentation boundaries.
- Route initial loads, retries, destination and sort changes, successful mutations, and repository change notifications through one feature-model-owned refresh task. Destination, sort, retry, and mutation requests may cancel work for an obsolete query. File-system notifications must never cancel an in-flight read: coalesce notifications before a read starts, then schedule at most one trailing refresh for changes received during it. Reconcile folder-tree, media, thumbnail, viewer, and selection state only from the latest result. Keep existing content mounted during same-destination refreshes; blocking loading presentation is only for initial loads, retries, and destination changes.
- Apply refreshed media identities through the platform's incremental collection diffing so unchanged items and their selection remain in place.
- Apply direct-folder sorting by date added, name, or file size in `MediaRepository`. The feature model owns only the selected sort option and direction.
- Include a normalized date-added value and relative path in each `MediaItem` returned for Recents. Resolve the date from `addedToDirectoryDate`, then creation date, then content-modification date; leave it absent if the volume provides none of them.
- Sort recursive Recents results in `MediaRepository`: dated items descending by date added, then deterministic relative-path order, followed by undated items in relative-path order.
- Run blocking file-system enumeration outside the main actor and honor cancellation while building folder and Recents results.
- If the creation-date fallback is used, include Apple's required-reason API declaration in the app privacy manifest.
- Add focused repository protocols for other data sources as they become necessary; do not access those sources directly from views or feature models.
- Map platform and persistence representations into Oriel models inside the repository implementation.
- Use asynchronous, throwing repository operations for I/O that can wait or fail.
- Keep repositories free of navigation and presentation state.

#### Platform recents implementations

- On macOS, back `RecentsFolderRepository` with `NSDocumentController.shared`. Map `recentDocumentURLs` to Oriel `RecentFolder` models, record with `noteNewRecentDocumentURL(_:)`, and clear with `clearRecentDocuments(_:)`.
- Do not maintain a second macOS recents database and do not use the deprecated `LSSharedFileList` APIs.
- If a macOS entry is confirmed deleted, snapshot the surviving system entries, clear the system list, and add the survivors again from oldest to newest to preserve their order.
- Handle AppKit's Open Recent application callback and forward the selected folder into the normal feature-model and window-opening flow.
- On iPadOS and iOS, back `RecentsFolderRepository` with Oriel-owned persistence because UIKit provides folder picking but no API that returns a recent-folders list to a custom Welcome screen.
- Register the correct platform implementation through Factory; consumers depend only on `RecentsFolderRepository`.
- On every platform, use `FolderAccessRepository` for bookmark identity and sandbox access. A system-managed recent entry is not a substitute for persistent authorization.
- Resolve bookmarks when loading recents, use the returned current URL, and replace stale bookmark data.
- Remove an entry only when deletion is confirmed. Bookmark resolution can also fail because a volume can't be mounted, so temporary unavailability must not trigger pruning.
- Treat deletion as confirmed only when the platform reports it explicitly or when the containing volume or provider is reachable and the tracked folder no longer exists. Resolution failure by itself is insufficient.

### Protocol boundaries

- Give every app-defined behavioral type a protocol, including repositories, feature models, services, coordinators, and other dependency-bearing helpers.
- Type dependencies and Factory registrations by protocol rather than by concrete implementation.
- Refer to a concrete implementation only in its declaration and in the Factory composition root that constructs it. SwiftUI views may also own a concrete observable feature model where required by SwiftUI's state and Observation APIs.
- Keep data-only Swift models as concrete value types; they are values passed across protocol boundaries, not dependency implementations.
- SwiftUI `View` types do not need companion protocols. Use Foundation and Apple-framework types directly when they are not crossing a repository boundary as raw data.

### Dependency injection with Factory

- Add [Factory](https://github.com/hmlongco/Factory) with Swift Package Manager and import its `FactoryKit` product.
- Register repositories, feature models, and every other app-defined dependency in Factory container extensions.
- Construct the object graph in Factory registrations. A type must not instantiate one of its own dependencies directly.
- Prefer constructor injection inside registrations so required dependencies are explicit. Resolve dependencies at the app, scene, or root-feature boundary rather than throughout business logic.
- Give each folder window or tab its own feature-model state. Share a dependency through a Factory scope only when its lifetime is intentionally shared.
- Override protocol registrations with fakes for tests and SwiftUI previews; previews must not access live folders or persisted recents.

### SwiftUI data flow

- Implement UI-facing feature models as `@MainActor @Observable` reference types that conform to their feature-model protocols.
- Give each piece of mutable state one owner at the narrowest stable app, scene, or view boundary.
- Store an owned observable feature model with `@State`. Pass it to nearby child views as a normal property, or place it in the environment when many descendants share it.
- Use `@Bindable` only when a child view needs bindings to mutable properties. Keep transient, view-only state in local `@State`.
- Make views declarative: read model state, render it, and forward user actions to intent methods on the feature model. Views must not perform repository access or contain business logic.
- Keep window and tab state isolated so activity in one folder cannot mutate another folder's browsing state.
- Perform blocking or expensive work outside the main actor. Repository implementations own the required isolation and return models safely to the main-actor feature model.
- Use Observation for new code rather than `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject`.
- Prefer a separate `View` type when a subsection owns state or should update independently; otherwise keep the view hierarchy as small as clarity allows.

### Project organization

```text
Oriel/
  Models/                 Oriel value models
  Repositories/           Protocols and concrete data-access implementations
  Features/<Feature>/     Views and observable feature models
  DependencyInjection/    Factory registrations and scopes
```

Create folders only when their first implementation exists; this structure is a placement rule, not a requirement for empty scaffolding.

### References

- [SwiftUI Group Lab, WWDC26](https://developer.apple.com/videos/play/wwdc2026/8006/): SwiftUI is architecture-agnostic; Apple recommends idiomatic Observation and data flow rather than a mandatory named pattern.
- [Managing model data in your app](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app): Apple guidance for `@Observable`, `@State`, environment sharing, bindings, and a single source of truth.
- [Factory](https://github.com/hmlongco/Factory): official registration, resolution, Observation, preview, testing, and Swift Package Manager guidance.
- [NSDocumentController](https://developer.apple.com/documentation/appkit/nsdocumentcontroller): AppKit's system-managed per-application Open Recent list, including support for non-`NSDocument` apps.
- [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories): folder selection, picker behavior, persistent bookmarks, and the `UIDocumentBrowserViewController` folder limitation on iPadOS and iOS.
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox): persistent access through security-scoped bookmarks.
- [URL bookmarks and security scope](https://developer.apple.com/documentation/foundation/nsurl): persistent references that normally follow file-system resources across moves and renames.
- [Resolving bookmark data](https://developer.apple.com/documentation/foundation/url/init%28resolvingbookmarkdata%3Aoptions%3Arelativeto%3Abookmarkdataisstale%3A%29-3ic6f): current URL resolution and stale-bookmark handling.
- [Checking resource reachability](https://developer.apple.com/documentation/foundation/url/checkresourceisreachable%28%29): existence and backing-store reachability checks for file URLs.
- [Date added to a directory](https://developer.apple.com/documentation/foundation/urlresourcevalues/addedtodirectorydate): Foundation metadata for when a resource was created, moved, or renamed into its parent directory, including its volume-support limitation.
- [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus): Apple guidance on relevant commands, short menus, availability, grouping, consistency, and destructive actions.
- [FileManager](https://developer.apple.com/documentation/foundation/filemanager): Foundation operations for inspecting, creating, copying, moving, trashing, and removing filesystem items.
- [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace): macOS system operations for opening, duplicating, recycling, and revealing files in Finder.
- [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink): SwiftUI's system sharing presentation for `Transferable` content such as file URLs.

## Planned phases

1. Establish the architecture skeleton, Factory registrations, and initial protocols and models.
2. Implement folder selection, retained access, and window lifecycle.
3. Implement the folder sidebar, recursive Recents destination, media browser, single selection, drag-and-drop transfers, and context-menu file operations.
4. Implement picture viewing, video playback, keyboard navigation, zooming, and panning.
5. Add loading, empty, and error states, then verify each supported platform.
