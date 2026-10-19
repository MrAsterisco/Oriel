import SwiftUI

struct PeopleGalleryView: View {
  let people: [PersonGroup]
  let isScanning: Bool
  let errorMessage: String?
  let onOpen: (PersonGroup) -> Void
  let onRetry: () -> Void
  let thumbnails: [FaceThumbnailSource.ID: MediaThumbnail]
  let onLoadThumbnail: (FaceThumbnailSource) async -> Void
  let onDiscardThumbnail: (FaceThumbnailSource) -> Void

  var body: some View {
    VStack(spacing: 0) {
      if isScanning {
        HStack {
          ProgressView().controlSize(.small)
          Text("Scanning for people…").font(.callout).foregroundStyle(.secondary)
          Spacer()
        }.padding()
        Divider()
      }
      if let errorMessage {
        HStack {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
          Spacer()
          Button("Try Again", action: onRetry)
        }.padding()
        Divider()
      }
      if people.isEmpty {
        ContentUnavailableView(
          isScanning
            ? "Looking for People"
            : errorMessage == nil ? "No People Found" : "Couldn’t Scan People",
          systemImage: "person.2",
          description: Text(
            isScanning
              ? "People will appear here as faces are found in this folder and its subfolders."
              : errorMessage == nil
                ? "No recognizable faces were found in this folder or its subfolders."
                : "Try scanning again to find people in this folder."))
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220))], spacing: 24) {
            ForEach(people) { person in
              Button {
                onOpen(person)
              } label: {
                VStack(spacing: 8) {
                  FaceThumbnailView(
                    source: person.thumbnail, thumbnail: thumbnails[person.thumbnail.id], size: 112,
                    onLoad: onLoadThumbnail, onDiscard: onDiscardThumbnail)
                  Text(person.name).font(.headline).lineLimit(1)
                  Text(person.items.count == 1 ? "1 Photo" : "\(person.items.count) Photos")
                    .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(8).contentShape(.rect)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(person.name), \(person.items.count) photos")
              .accessibilityHint("Open this person’s photos")
            }
          }.padding()
        }
      }
    }
  }
}

struct PersonSearchHeaderView: View {
  let faces: [DetectedFace]
  let selectedIndex: Int?
  let isSearching: Bool
  let errorMessage: String?
  let onSelect: (Int) -> Void
  let onRetry: () -> Void
  let thumbnails: [FaceThumbnailSource.ID: MediaThumbnail]
  let onLoadThumbnail: (FaceThumbnailSource) async -> Void
  let onDiscardThumbnail: (FaceThumbnailSource) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !faces.isEmpty {
        Text(faces.count > 1 ? "Choose the person to find" : "Find photos of this person")
          .font(.headline)
        ScrollView(.horizontal) {
          LazyHStack(spacing: 12) {
            ForEach(faces.indices, id: \.self) { index in
              Button {
                onSelect(index)
              } label: {
                FaceThumbnailView(
                  source: faces[index].thumbnail, thumbnail: thumbnails[faces[index].thumbnail.id],
                  size: 56,
                  onLoad: onLoadThumbnail, onDiscard: onDiscardThumbnail
                )
                .padding(4)
                .overlay {
                  if selectedIndex == index { Circle().stroke(.tint, lineWidth: 3) }
                }
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Person \(index + 1)")
              .accessibilityHint("Search for photos of this person")
              .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
            }
          }.padding(4)
        }
      }
      if isSearching {
        HStack {
          ProgressView().controlSize(.small)
          Text(faces.isEmpty ? "Reading reference image…" : "Searching all pictures…")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      if let errorMessage {
        HStack {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
          Spacer()
          if selectedIndex != nil { Button("Try Again", action: onRetry) }
        }
      }
      Text("Searches this folder and all subfolders. Images are processed on this device.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct FaceThumbnailView: View {
  let source: FaceThumbnailSource
  let thumbnail: MediaThumbnail?
  let size: CGFloat
  let onLoad: (FaceThumbnailSource) async -> Void
  let onDiscard: (FaceThumbnailSource) -> Void

  var body: some View {
    Group {
      if let thumbnail {
        Image(decorative: thumbnail.image.cgImage, scale: 1).resizable().scaledToFill()
      } else {
        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size).clipShape(.circle)
    .task(id: source.id) { await onLoad(source) }
    .onDisappear { onDiscard(source) }
    .onChange(of: source) { previous, _ in onDiscard(previous) }
  }
}
