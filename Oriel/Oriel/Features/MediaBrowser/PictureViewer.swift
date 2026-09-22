import CoreGraphics
import SwiftUI

struct PictureViewer: View {
  let image: CGImage
  let zoomScale: CGFloat
  let panOffset: CGSize
  let onTransformEnded: (CGFloat, CGSize) -> Void

  var body: some View {
    #if os(macOS)
      MacPictureScrollView(
        image: image,
        zoomScale: zoomScale,
        panOffset: panOffset,
        onTransformEnded: onTransformEnded
      )
    #else
      UIKitPictureScrollView(
        image: image,
        zoomScale: zoomScale,
        panOffset: panOffset,
        onTransformEnded: onTransformEnded
      )
    #endif
  }
}

#if os(macOS)
  import AppKit

  private struct MacPictureScrollView: NSViewRepresentable {
    let image: CGImage
    let zoomScale: CGFloat
    let panOffset: CGSize
    let onTransformEnded: (CGFloat, CGSize) -> Void

    func makeNSView(context: Context) -> PictureScrollView {
      PictureScrollView()
    }

    func updateNSView(_ scrollView: PictureScrollView, context: Context) {
      scrollView.onTransformEnded = onTransformEnded
      scrollView.update(image: image, zoomScale: zoomScale, panOffset: panOffset)
    }
  }

  private final class PictureScrollView: NSScrollView {
    private let canvasView = NSView()
    private let imageView = NSImageView()
    private var currentImage: CGImage?
    private var dragOrigin: NSPoint?
    private var isApplyingTransform = false

    var onTransformEnded: ((CGFloat, CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      drawsBackground = true
      backgroundColor = .black
      hasHorizontalScroller = true
      hasVerticalScroller = true
      autohidesScrollers = true
      allowsMagnification = true
      minMagnification = 1
      maxMagnification = 8

      canvasView.wantsLayer = true
      imageView.imageAlignment = .alignCenter
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.wantsLayer = true
      canvasView.addSubview(imageView)
      documentView = canvasView

      addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(didDrag(_:))))
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(didEndInteraction),
        name: NSScrollView.didEndLiveMagnifyNotification,
        object: self
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(didEndInteraction),
        name: NSScrollView.didEndLiveScrollNotification,
        object: self
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
      super.layout()
      let size = contentSize
      guard size.width > 0, size.height > 0, canvasView.frame.size != size else { return }
      canvasView.frame = CGRect(origin: .zero, size: size)
      imageView.frame = canvasView.bounds.insetBy(dx: 16, dy: 16)
    }

    override func scrollWheel(with event: NSEvent) {
      let isGestureScroll = !event.phase.isEmpty || !event.momentumPhase.isEmpty
      guard !isGestureScroll else {
        super.scrollWheel(with: event)
        return
      }

      let delta = min(max(event.scrollingDeltaY, -8), 8)
      let scale = min(max(magnification * pow(1.05, delta), minMagnification), maxMagnification)
      guard abs(scale - magnification) > 0.0001 else { return }

      let pointerLocation = canvasView.convert(event.locationInWindow, from: nil)
      setMagnification(scale, centeredAt: pointerLocation)
      reportTransform()
    }

    func update(image: CGImage, zoomScale: CGFloat, panOffset: CGSize) {
      if currentImage !== image {
        currentImage = image
        imageView.image = NSImage(
          cgImage: image,
          size: NSSize(width: image.width, height: image.height)
        )
      }

      layoutSubtreeIfNeeded()
      apply(zoomScale: zoomScale, panOffset: panOffset)
    }

    private func apply(zoomScale: CGFloat, panOffset: CGSize) {
      isApplyingTransform = true
      defer { isApplyingTransform = false }

      let scale = min(max(zoomScale, minMagnification), maxMagnification)
      if abs(magnification - scale) > 0.0001 {
        setMagnification(scale, centeredAt: visibleCenter)
      }

      let visibleSize = contentView.bounds.size
      let origin = NSPoint(
        x: canvasView.bounds.midX - panOffset.width / scale - visibleSize.width / 2,
        y: canvasView.bounds.midY + panOffset.height / scale - visibleSize.height / 2
      )
      contentView.scroll(to: origin)
      reflectScrolledClipView(contentView)
    }

    @objc private func didDrag(_ gesture: NSPanGestureRecognizer) {
      guard magnification > 1 else { return }
      switch gesture.state {
      case .began:
        dragOrigin = contentView.bounds.origin
      case .changed:
        guard let dragOrigin else { return }
        let translation = gesture.translation(in: self)
        contentView.scroll(
          to: NSPoint(
            x: dragOrigin.x - translation.x / magnification,
            y: dragOrigin.y + translation.y / magnification
          )
        )
        reflectScrolledClipView(contentView)
      case .ended, .cancelled:
        dragOrigin = nil
        reportTransform()
      default:
        break
      }
    }

    @objc private func didEndInteraction() {
      reportTransform()
    }

    private func reportTransform() {
      guard !isApplyingTransform else { return }
      let visibleRect = documentVisibleRect
      let panOffset = CGSize(
        width: (canvasView.bounds.midX - visibleRect.midX) * magnification,
        height: (visibleRect.midY - canvasView.bounds.midY) * magnification
      )
      onTransformEnded?(magnification, magnification == 1 ? .zero : panOffset)
    }

    private var visibleCenter: NSPoint {
      let visibleRect = documentVisibleRect
      return NSPoint(x: visibleRect.midX, y: visibleRect.midY)
    }
  }
#else
  import UIKit

  private struct UIKitPictureScrollView: UIViewRepresentable {
    let image: CGImage
    let zoomScale: CGFloat
    let panOffset: CGSize
    let onTransformEnded: (CGFloat, CGSize) -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(onTransformEnded: onTransformEnded)
    }

    func makeUIView(context: Context) -> PictureScrollView {
      let scrollView = PictureScrollView()
      scrollView.delegate = context.coordinator
      return scrollView
    }

    func updateUIView(_ scrollView: PictureScrollView, context: Context) {
      context.coordinator.onTransformEnded = onTransformEnded
      context.coordinator.isApplyingTransform = true
      scrollView.update(image: image, zoomScale: zoomScale, panOffset: panOffset)
      context.coordinator.isApplyingTransform = false
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
      var isApplyingTransform = false
      var onTransformEnded: (CGFloat, CGSize) -> Void

      init(onTransformEnded: @escaping (CGFloat, CGSize) -> Void) {
        self.onTransformEnded = onTransformEnded
      }

      func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        (scrollView as? PictureScrollView)?.canvasView
      }

      func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
      ) {
        reportTransform(from: scrollView)
      }

      func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportTransform(from: scrollView) }
      }

      func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportTransform(from: scrollView)
      }

      private func reportTransform(from scrollView: UIScrollView) {
        guard !isApplyingTransform else { return }
        let centerOffset = CGPoint(
          x: max((scrollView.contentSize.width - scrollView.bounds.width) / 2, 0),
          y: max((scrollView.contentSize.height - scrollView.bounds.height) / 2, 0)
        )
        let panOffset = CGSize(
          width: centerOffset.x - scrollView.contentOffset.x,
          height: centerOffset.y - scrollView.contentOffset.y
        )
        onTransformEnded(
          scrollView.zoomScale,
          scrollView.zoomScale == 1 ? .zero : panOffset
        )
      }
    }
  }

  private final class PictureScrollView: UIScrollView {
    let canvasView = UIView()
    private let imageView = UIImageView()
    private var baseSize = CGSize.zero
    private var currentImage: CGImage?

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
      contentInsetAdjustmentBehavior = .never
      minimumZoomScale = 1
      maximumZoomScale = 8
      showsHorizontalScrollIndicator = true
      showsVerticalScrollIndicator = true

      imageView.contentMode = .scaleAspectFit
      canvasView.addSubview(imageView)
      addSubview(canvasView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard bounds.size.width > 0, bounds.size.height > 0, baseSize != bounds.size else {
        return
      }
      baseSize = bounds.size
      canvasView.frame = CGRect(origin: .zero, size: baseSize)
      imageView.frame = canvasView.bounds.insetBy(dx: 16, dy: 16)
      contentSize = baseSize
    }

    func update(image: CGImage, zoomScale: CGFloat, panOffset: CGSize) {
      if currentImage !== image {
        currentImage = image
        imageView.image = UIImage(cgImage: image)
      }

      layoutIfNeeded()
      let scale = min(max(zoomScale, minimumZoomScale), maximumZoomScale)
      if abs(self.zoomScale - scale) > 0.0001 {
        setZoomScale(scale, animated: false)
      }
      let centerOffset = CGPoint(
        x: max((contentSize.width - bounds.width) / 2, 0),
        y: max((contentSize.height - bounds.height) / 2, 0)
      )
      contentOffset = CGPoint(
        x: centerOffset.x - panOffset.width,
        y: centerOffset.y - panOffset.height
      )
    }
  }
#endif
