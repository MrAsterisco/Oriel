import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
  let model: any WelcomeFeatureModelProtocol

  var body: some View {
#if os(macOS)
    HStack(spacing: 0) {
      branding
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      recentFolders
        .frame(width: 300)
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
    .background(.background)
    .ignoresSafeArea(.container, edges: .top)
#else
    ScrollView {
      content
        .padding(40)
    }
    .frame(minWidth: 360, minHeight: 440)
    .background(.background)
#endif
  }

  private var content: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 64) {
        branding
        recentFolders
      }

      VStack(spacing: 36) {
        branding
        recentFolders
      }
    }
    .frame(maxWidth: 760)
  }

  private var branding: some View {
    VStack(spacing: 16) {
      ZStack {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(.blue.gradient)
        Image(systemName: "photo.on.rectangle.angled")
          .font(.system(size: 52, weight: .medium))
          .foregroundStyle(.white)
      }
      .frame(width: 112, height: 112)
      .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
      .accessibilityHidden(true)

      VStack(spacing: 4) {
        Text("Oriel")
          .font(.largeTitle.bold())
        Text("Version \(model.appVersion)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Button("Open Folder", systemImage: "folder") {
        model.openFolderPicker()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut("o")
    }
    .frame(minWidth: 220)
  }

  private var recentFolders: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Recent Folders")
          .font(.headline)
        Spacer()
        if !model.recentFolders.isEmpty {
          Button("Clear") {
            Task { await model.clearRecents() }
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
      }

      if model.isLoadingRecents {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 160)
      } else if model.recentFolders.isEmpty {
        ContentUnavailableView(
          "No Recent Folders",
          systemImage: "folder",
          description: Text("Folders you open will appear here.")
        )
        .frame(minHeight: 160)
      } else {
        LazyVStack(spacing: 2) {
          ForEach(model.recentFolders) { folder in
            Button {
              Task { await model.openRecentFolder(folder) }
            } label: {
              HStack(spacing: 12) {
                Image(
                  systemName: folder.availability == .available
                    ? "folder" : "folder.badge.questionmark"
                )
                .foregroundStyle(
                  folder.availability == .available ? Color.accentColor : Color.secondary
                )
                .font(.title3)
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                  Text(folder.name)
                    .fontWeight(.medium)
                  Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 0)
              }
              .contentShape(.rect)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .frame(minWidth: 300, maxWidth: 420)
  }
}
