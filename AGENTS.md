# Oriel implementation rules

These rules apply to every change in this repository. Read the architecture section in `README.md` before implementing a feature.

## Required dependency flow

Follow this direction only:

```text
SwiftUI view -> @MainActor @Observable feature model -> repository protocol -> system API or persistence
```

Factory is the composition root that constructs and injects this graph.

## Data access and models

- Put all external data reads and writes in repository implementations, including file-system access, recent-folder sources, persistent folder authorization, media metadata, and thumbnails.
- Define a protocol for every repository. Recent-folder access goes through `RecentsFolderRepository`.
- Keep recency and folder authorization separate. `RecentsFolderRepository` lists, records, and clears recents; `FolderAccessRepository` persists and manages authorized folder access.
- Identify persisted folders with platform bookmarks or system recent-item references, never with an absolute path alone. Resolve each reference to its current URL so moves and renames are followed.
- Refresh stored bookmark data whenever resolution reports that it is stale.
- Validate recents before returning them. Remove the recent entry and its authorization only when the folder is confirmed deleted.
- Confirm deletion only from an explicit platform result or when the containing volume or provider is reachable and the tracked folder no longer exists. Bookmark-resolution failure alone is not proof of deletion.
- Do not classify an unmounted volume, disconnected network share, unavailable file provider, or authorization failure as deletion. Keep the entry available for reconnection or reauthorization.
- On macOS, implement `RecentsFolderRepository` with `NSDocumentController.shared`. Use `recentDocumentURLs`, `noteNewRecentDocumentURL(_:)`, and `clearRecentDocuments(_:)`; do not create a parallel recents store or use deprecated `LSSharedFileList` APIs.
- To remove a confirmed-deleted macOS entry, rebuild `NSDocumentController`'s system list from the surviving entries, adding them oldest first to preserve order. Do not persist that snapshot.
- Route macOS Open Recent callbacks through the normal feature-model and window-opening flow.
- On iPadOS and iOS, persist bookmark identities in Oriel's recent-folders list because the system folder picker doesn't expose one to a custom Welcome screen. Do not use `UIDocumentBrowserViewController` for folders.
- Register the platform-specific `RecentsFolderRepository` implementation with Factory. Consumers must remain platform-agnostic.
- Never treat a recent URL as proof of sandbox access. Create, persist, resolve, refresh, start, and stop bookmark-backed access through `FolderAccessRepository`; request selection again if restoration fails.
- Implement the sidebar's media **Recents** query in `MediaRepository`, not in a view or feature model. Recursively enumerate supported media under the current window or tab's root folder.
- Map `addedToDirectoryDate`, creation date, content-modification date, and relative path into `MediaItem`. Resolve date added in that order and leave it absent when none is available; never substitute the current time.
- Declare the creation-date API's required reason in `PrivacyInfo.xcprivacy` when implementing that fallback.
- Sort recent media in the repository with dated items newest first, using relative path as a deterministic tie-breaker, then undated items by relative path.
- Return all supported recursive results without an arbitrary age or count limit. Refresh on selection and known directory changes, and omit deleted or unsupported files.
- Reuse the normal media browser and viewer for Recents. Keyboard navigation and looping use the repository's current Recents ordering.
- Put all drag-and-drop and context-menu file mutations in `FileOperationRepository`. It owns folder creation, rename, duplicate, copy, move, paste, trash, and permanent deletion, plus metadata reads for Get Info. `MediaRepository` remains the media-query and sorting boundary.
- SwiftUI views may declare context menus, drag sources, drop destinations, sharing controls, and system presentations, but they only render feature-model state and forward intent. They must not inspect, copy, move, rename, delete, or coordinate files.
- Treat a selected folder's main media area and each writable sidebar folder row as drop destinations. The aggregate Recents destination is never a drop destination because it has no single physical folder, but its media items are drag sources.
- Accept only supported media and honor the copy or move operation negotiated by the platform, including modifier-key changes on macOS. Do not infer the operation from source or destination paths.
- Model transfer sources, destinations, and operations with Oriel-owned value types. Do not expose raw item providers or file coordinators across the repository boundary.
- Validate the destination and name conflicts before mutation. Treat a same-parent transfer as a no-op and never overwrite an existing file silently.
- For cross-volume or cross-provider moves, finish and validate the destination copy before deleting the source. Cancellation or copy failure must leave the original intact.
- Refresh affected folder, tree, and Recents results after a successful transfer, and surface failures through feature-model state.
- Use the same `FileOperationRepository` methods for equivalent drag-and-drop and context-menu commands; do not create parallel mutation paths.
- Use `FolderAccessRepository` for temporary access to destinations selected outside the current root. Do not persist that access unless the folder is separately opened as a root.
- Context-clicking or long-pressing a media item selects it before presenting its menu. Use the same applicable media menu in normal folder results, Recents, and the viewer.
- The media-item menu consists of: Open, macOS Open With, Share; Rename, Duplicate, Copy, Move To, platform reveal, Get Info; and Trash or confirmed permanent Delete last.
- A folder menu includes Open, window or tab opening where supported, New Folder, Paste, the applicable file-management commands, and Trash or confirmed permanent Delete last. The empty folder background includes New Folder, Paste, reveal, and Get Info.
- Never offer rename, duplicate, move, trash, or delete for the current root folder from inside Oriel. It is the window or tab's access anchor. The aggregate Recents destination has no folder-operation menu.
- Keep context menus to at most three groups. Hide unavailable commands instead of presenting operations that will fail, and mark destructive commands with platform-standard destructive styling.
- Rename only the base filename and preserve its extension. Reject invalid names and conflicts before mutation. Duplicate uses a platform-conventional unique sibling name.
- Prefer recoverable trash semantics. When unavailable, label the operation Delete, require confirmation, and confirm recursive deletion explicitly for nonempty folders.
- Register `FileOperationRepository` with Factory and override it with a fake in tests and previews. Return Oriel-owned operation-result and file-info models; do not expose pasteboard, item-provider, security-scope, file-coordination, or workspace objects.
- After a successful mutation, refresh affected `MediaRepository` results and reconcile folder-tree and selection state. A failure must leave the UI consistent with the actual filesystem.
- Keep media selection as transient feature-model state, represented by a stable media identity. Do not add a selection repository, service, or persistence layer.
- Support single selection in folder and Recents results. One primary click or tap selects without opening; selecting another item replaces it, and activating empty space clears it.
- Preserve selection across sorting and refreshes while the same identity remains in the current result. Clear it when changing destinations or when the item disappears.
- Activation selects and opens the item. Beginning a drag from an unselected item selects it first.
- Render platform-standard active and inactive selection styling and expose the selected state to accessibility APIs.
- Return Oriel-owned Swift models that wrap underlying system content. Do not expose raw persistence records, bookmarks, enumerators, or media-framework objects across repository boundaries.
- Keep models as data-only value types. They must not access repositories, persistence, navigation, or UI.
- Use `async throws` for repository I/O that can wait or fail.

## Protocols and Factory

- Abstract every app-defined behavioral type behind a protocol: repositories, feature models, services, coordinators, and dependency-bearing helpers.
- Depend on protocols, never concrete implementations.
- Refer to a concrete implementation only in its own declaration, its Factory registration, or a SwiftUI view when SwiftUI state ownership requires the concrete observable type.
- Swift models are concrete values passed across protocol boundaries. SwiftUI views and Foundation or Apple-framework types do not require wrapper protocols.
- Register every app-defined dependency in Factory container extensions using `FactoryKit`.
- Construct dependencies in Factory registrations, preferably with constructor injection. Do not instantiate dependencies inside their consumers.
- Resolve from Factory only at app, scene, or root-feature boundaries. Do not use the container as a service locator inside business logic.
- Override protocol registrations with fakes in tests and previews. Never let previews access live folders or persisted recents.
- Choose Factory scopes deliberately. Folder windows and tabs must not share feature-model state.

## SwiftUI architecture

- Use SwiftUI's Observation-based data flow. New UI-facing feature models are `@MainActor @Observable` reference types that conform to a protocol.
- Give each state value one owner at the narrowest stable app, scene, or view boundary.
- Store an owned observable feature model with `@State`.
- Pass model data directly to nearby children; use the environment only for state shared broadly through a hierarchy.
- Use `@Bindable` only when a child needs mutable bindings. Use local `@State` for transient view-only state.
- Views render state and forward user intent to feature-model methods. They contain no data access or business logic.
- Do not introduce `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject` for new code.
- Keep each folder window or tab's navigation, selection, zoom, and playback state independent.
- Keep expensive or blocking work off the main actor; repositories own I/O isolation and return safe model values.
- Create a separate SwiftUI view type when a subsection owns state or needs independent updates. Do not add empty layers or speculative abstractions.

## File placement

- `Models/`: Oriel value models.
- `Repositories/`: repository protocols and implementations.
- `Features/<Feature>/`: SwiftUI views and observable feature models.
- `DependencyInjection/`: Factory registrations and scopes.

Create a directory when its first real file is added; do not create empty scaffolding.
