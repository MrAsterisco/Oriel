import CoreGraphics
import SwiftUI

private let cropCanvasCoordinateSpace = "cropCanvas"

struct PictureCropViewer: View {
  let image: CGImage
  let crop: PictureCrop
  let onCropRectChanged: (MediaNormalizedRect) -> Void

  var body: some View {
    GeometryReader { proxy in
      let imageSize = fittedSize(
        aspectRatio: CGFloat(crop.originalSize.width) / CGFloat(crop.originalSize.height),
        in: CGSize(
          width: max(proxy.size.width - 72, 1),
          height: max(proxy.size.height - 72, 1)
        )
      )

      ZStack {
        Color.black
        CropCanvas(
          image: image,
          crop: crop,
          imageSize: imageSize,
          onCropRectChanged: onCropRectChanged
        )
        .frame(width: imageSize.width, height: imageSize.height)
      }
    }
  }

  private func fittedSize(aspectRatio: CGFloat, in availableSize: CGSize) -> CGSize {
    guard aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
    if availableSize.width / availableSize.height > aspectRatio {
      return CGSize(
        width: availableSize.height * aspectRatio,
        height: availableSize.height
      )
    }
    return CGSize(
      width: availableSize.width,
      height: availableSize.width / aspectRatio
    )
  }
}

private struct CropCanvas: View {
  let image: CGImage
  let crop: PictureCrop
  let imageSize: CGSize
  let onCropRectChanged: (MediaNormalizedRect) -> Void

  var body: some View {
    let selectionRect = displayRect(for: crop.normalizedRect)

    ZStack {
      Image(decorative: image, scale: 1)
        .resizable()
        .interpolation(.high)
        .frame(width: imageSize.width, height: imageSize.height)

      CropShade(selectionRect: selectionRect, imageSize: imageSize)

      Rectangle()
        .fill(.clear)
        .contentShape(.rect)
        .frame(width: selectionRect.width, height: selectionRect.height)
        .position(x: selectionRect.midX, y: selectionRect.midY)
        .gesture(moveGesture)
        .accessibilityLabel("Crop selection")
        .accessibilityValue(
          "\(crop.pixelRect.width) by \(crop.pixelRect.height) pixels"
        )
        .accessibilityHint("Drag to move the crop selection")

      CropGrid(selectionRect: selectionRect)

      ForEach(CropCorner.allCases) { corner in
        CropHandle(
          corner: corner,
          crop: crop,
          imageSize: imageSize,
          onCropRectChanged: onCropRectChanged
        )
        .position(
          x: corner.isLeading ? selectionRect.minX : selectionRect.maxX,
          y: corner.isTop ? selectionRect.minY : selectionRect.maxY
        )
      }
    }
    .frame(width: imageSize.width, height: imageSize.height)
    .coordinateSpace(name: cropCanvasCoordinateSpace)
  }

  @State private var moveStartRect: MediaNormalizedRect?

  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(cropCanvasCoordinateSpace))
      .onChanged { value in
        let startRect = moveStartRect ?? crop.normalizedRect
        moveStartRect = startRect
        onCropRectChanged(
          MediaNormalizedRect(
            x: startRect.x + Double(value.translation.width / max(imageSize.width, 1)),
            y: startRect.y + Double(value.translation.height / max(imageSize.height, 1)),
            width: startRect.width,
            height: startRect.height
          )
        )
      }
      .onEnded { _ in moveStartRect = nil }
  }

  private func displayRect(for rect: MediaNormalizedRect) -> CGRect {
    CGRect(
      x: CGFloat(rect.x) * imageSize.width,
      y: CGFloat(rect.y) * imageSize.height,
      width: CGFloat(rect.width) * imageSize.width,
      height: CGFloat(rect.height) * imageSize.height
    )
  }
}

private struct CropShade: View {
  let selectionRect: CGRect
  let imageSize: CGSize

  var body: some View {
    let color = Color.black.opacity(0.55)
    ZStack {
      Rectangle()
        .fill(color)
        .frame(width: imageSize.width, height: selectionRect.minY)
        .position(x: imageSize.width / 2, y: selectionRect.minY / 2)
      Rectangle()
        .fill(color)
        .frame(width: imageSize.width, height: imageSize.height - selectionRect.maxY)
        .position(
          x: imageSize.width / 2,
          y: selectionRect.maxY + (imageSize.height - selectionRect.maxY) / 2
        )
      Rectangle()
        .fill(color)
        .frame(width: selectionRect.minX, height: selectionRect.height)
        .position(x: selectionRect.minX / 2, y: selectionRect.midY)
      Rectangle()
        .fill(color)
        .frame(width: imageSize.width - selectionRect.maxX, height: selectionRect.height)
        .position(
          x: selectionRect.maxX + (imageSize.width - selectionRect.maxX) / 2,
          y: selectionRect.midY
        )
    }
    .frame(width: imageSize.width, height: imageSize.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct CropGrid: View {
  let selectionRect: CGRect

  var body: some View {
    Path { path in
      path.addRect(selectionRect)
      for fraction: CGFloat in [1.0 / 3.0, 2.0 / 3.0] {
        let x = selectionRect.minX + selectionRect.width * fraction
        path.move(to: CGPoint(x: x, y: selectionRect.minY))
        path.addLine(to: CGPoint(x: x, y: selectionRect.maxY))
        let y = selectionRect.minY + selectionRect.height * fraction
        path.move(to: CGPoint(x: selectionRect.minX, y: y))
        path.addLine(to: CGPoint(x: selectionRect.maxX, y: y))
      }
    }
    .stroke(.white.opacity(0.8), lineWidth: 1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct CropHandle: View {
  let corner: CropCorner
  let crop: PictureCrop
  let imageSize: CGSize
  let onCropRectChanged: (MediaNormalizedRect) -> Void

  @State private var dragStartRect: MediaNormalizedRect?

  var body: some View {
    Circle()
      .fill(.tint)
      .stroke(.white, lineWidth: 2)
      .frame(width: 18, height: 18)
      .frame(width: 44, height: 44)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named(cropCanvasCoordinateSpace))
          .onChanged { value in
            let startRect = dragStartRect ?? crop.normalizedRect
            dragStartRect = startRect
            onCropRectChanged(
              adjustedRect(
                from: startRect,
                horizontalChange: Double(value.translation.width / max(imageSize.width, 1)),
                verticalChange: Double(value.translation.height / max(imageSize.height, 1))
              )
            )
          }
          .onEnded { _ in dragStartRect = nil }
      )
      .accessibilityLabel(corner.accessibilityLabel)
      .accessibilityValue("\(crop.pixelRect.width) by \(crop.pixelRect.height) pixels")
      .accessibilityAdjustableAction { direction in
        let change = direction == .increment ? 0.05 : -0.05
        onCropRectChanged(
          adjustedRect(
            from: crop.normalizedRect,
            horizontalChange: corner.horizontalDirection * change,
            verticalChange: corner.verticalDirection * change
          )
        )
      }
  }

  private func adjustedRect(
    from rect: MediaNormalizedRect,
    horizontalChange: Double,
    verticalChange: Double
  ) -> MediaNormalizedRect {
    let minimumWidth = max(
      18 / Double(max(imageSize.width, 1)), 1 / Double(crop.originalSize.width))
    let minimumHeight = max(
      18 / Double(max(imageSize.height, 1)),
      1 / Double(crop.originalSize.height)
    )
    var minX = rect.x
    var minY = rect.y
    var maxX = rect.x + rect.width
    var maxY = rect.y + rect.height

    if corner.isLeading {
      minX = min(max(rect.x + horizontalChange, 0), maxX - minimumWidth)
    } else {
      maxX = max(min(maxX + horizontalChange, 1), minX + minimumWidth)
    }
    if corner.isTop {
      minY = min(max(rect.y + verticalChange, 0), maxY - minimumHeight)
    } else {
      maxY = max(min(maxY + verticalChange, 1), minY + minimumHeight)
    }

    return MediaNormalizedRect(
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY
    )
  }
}

private enum CropCorner: CaseIterable, Identifiable {
  case topLeading
  case topTrailing
  case bottomLeading
  case bottomTrailing

  var id: Self { self }

  var isLeading: Bool {
    self == .topLeading || self == .bottomLeading
  }

  var isTop: Bool {
    self == .topLeading || self == .topTrailing
  }

  var horizontalDirection: Double {
    isLeading ? -1 : 1
  }

  var verticalDirection: Double {
    isTop ? -1 : 1
  }

  var accessibilityLabel: String {
    switch self {
    case .topLeading: "Top left crop handle"
    case .topTrailing: "Top right crop handle"
    case .bottomLeading: "Bottom left crop handle"
    case .bottomTrailing: "Bottom right crop handle"
    }
  }
}
