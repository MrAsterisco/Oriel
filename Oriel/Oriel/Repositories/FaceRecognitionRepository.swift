import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

nonisolated protocol FaceRecognitionRepository: Sendable {
  func thumbnail(for source: FaceThumbnailSource) async throws -> MediaThumbnail
  func faces(in item: MediaItem) async throws -> [DetectedFace]
}

actor VisionFaceRecognitionRepository: FaceRecognitionRepository {
  private var model: MLModel?
  private let thumbnailLimit: Int
  private var thumbnails: [FaceThumbnailSource.ID: MediaThumbnail] = [:]
  private var thumbnailOrder: [FaceThumbnailSource.ID] = []

  init(thumbnailLimit: Int = 128) {
    precondition(thumbnailLimit > 0)
    self.thumbnailLimit = thumbnailLimit
  }

  func thumbnail(for source: FaceThumbnailSource) async throws -> MediaThumbnail {
    try Task.checkCancellation()
    if let cached = thumbnails[source.id] { return cached }
    let startedAccess = source.id.item.id.url.startAccessingSecurityScopedResource()
    defer { if startedAccess { source.id.item.id.url.stopAccessingSecurityScopedResource() } }
    let thumbnail = try autoreleasepool {
      let image = try Self.sourceImage(at: source.id.item.id.url)
      guard let crop = Self.alignedFace(in: image, transform: source.transform) else {
        throw MediaRepositoryError.thumbnailUnavailable
      }
      return MediaThumbnail(image: MediaImage(cgImage: crop))
    }
    try Task.checkCancellation()
    // Every entry is a 112 × 112 RGBA crop: 128 entries retain at most 6.125 MiB of pixels.
    if thumbnailOrder.count == thumbnailLimit {
      thumbnails.removeValue(forKey: thumbnailOrder.removeFirst())
    }
    thumbnailOrder.append(source.id)
    thumbnails[source.id] = thumbnail
    return thumbnail
  }

  nonisolated private static func sourceImage(at url: URL) throws -> CGImage {
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 2048,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw MediaRepositoryError.invalidPicture }
    return image
  }

  func faces(in item: MediaItem) async throws -> [DetectedFace] {
    try Task.checkCancellation()
    return try autoreleasepool {
      let image = try Self.sourceImage(at: item.id.url)
      let request = VNDetectFaceLandmarksRequest()
      request.preferBackgroundProcessing = true
      try VNImageRequestHandler(cgImage: image).perform([request])
      // Stable left-to-right ordering gives faces in the same first photo distinct identities.
      let observations = (request.results ?? []).sorted {
        if $0.boundingBox.minX != $1.boundingBox.minX {
          return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return $0.boundingBox.minY > $1.boundingBox.minY
      }
      return try observations.enumerated().compactMap { index, face in
        try Task.checkCancellation()
        guard let transform = Self.faceTransform(face, in: image),
          let aligned = Self.alignedFace(in: image, transform: transform)
        else { return nil }
        let model = try recognitionModel()
        let input = try MLFeatureValue(
          cgImage: aligned, pixelsWide: 112, pixelsHigh: 112,
          pixelFormatType: kCVPixelFormatType_32BGRA, options: [:])
        let output = try model.prediction(
          from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let values = output.featureValue(for: "embedding")?.multiArrayValue,
          values.count == 128
        else { throw PeopleRepositoryError.invalidEmbedding }
        return DetectedFace(
          embedding: (0..<values.count).map { values[$0].floatValue },
          thumbnail: FaceThumbnailSource(
            id: .init(item: item, faceIndex: index), transform: transform))
      }
    }
  }

  private func recognitionModel() throws -> MLModel {
    if let model { return model }
    guard let url = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") else {
      throw PeopleRepositoryError.modelUnavailable
    }
    let configuration = MLModelConfiguration()
    // Leave the GPU available for browsing and rendering while recognition runs.
    configuration.computeUnits = .cpuAndNeuralEngine
    let loaded = try MLModel(contentsOf: url, configuration: configuration)
    model = loaded
    return loaded
  }

  nonisolated private static func faceTransform(_ face: VNFaceObservation, in image: CGImage)
    -> CGAffineTransform?
  {
    guard let landmarks = face.landmarks,
      let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
      let lips = landmarks.outerLips, lips.pointCount > 0
    else { return nil }
    func point(_ point: CGPoint) -> CGPoint {
      CGPoint(
        x: (face.boundingBox.minX + point.x * face.boundingBox.width) * CGFloat(image.width),
        y: (face.boundingBox.minY + point.y * face.boundingBox.height) * CGFloat(image.height))
    }
    func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
      let sum = region.normalizedPoints.reduce(CGPoint.zero) {
        CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
      }
      return point(
        CGPoint(x: sum.x / CGFloat(region.pointCount), y: sum.y / CGFloat(region.pointCount)))
    }
    guard leftEye.pointCount > 0, rightEye.pointCount > 0 else { return nil }
    let eyes = [center(leftEye), center(rightEye)].sorted { $0.x < $1.x }
    let mouth = lips.normalizedPoints.map(point).sorted { $0.x < $1.x }
    let source = eyes + [mouth[0], mouth[mouth.count - 1]]
    // SFace's canonical landmark positions, expressed in Core Graphics' bottom-left coordinates.
    let target = [
      CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
      CGPoint(x: 41.5493, y: 112 - 92.3655), CGPoint(x: 70.7299, y: 112 - 92.2041),
    ]
    return alignmentTransform(from: source, to: target)
  }

  nonisolated private static func alignedFace(in image: CGImage, transform: CGAffineTransform)
    -> CGImage?
  {
    guard
      let context = CGContext(
        data: nil, width: 112, height: 112, bitsPerComponent: 8,
        bytesPerRow: 112 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.concatenate(transform)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  nonisolated static func alignmentTransform(from source: [CGPoint], to target: [CGPoint])
    -> CGAffineTransform?
  {
    guard source.count == target.count, source.count >= 2 else { return nil }
    let count = CGFloat(source.count)
    let meanSource = source.reduce(CGPoint.zero) {
      CGPoint(x: $0.x + $1.x / count, y: $0.y + $1.y / count)
    }
    let meanTarget = target.reduce(CGPoint.zero) {
      CGPoint(x: $0.x + $1.x / count, y: $0.y + $1.y / count)
    }
    var denominator: CGFloat = 0
    var real: CGFloat = 0
    var imaginary: CGFloat = 0
    for (source, target) in zip(source, target) {
      let x = source.x - meanSource.x
      let y = source.y - meanSource.y
      let u = target.x - meanTarget.x
      let v = target.y - meanTarget.y
      denominator += x * x + y * y
      real += x * u + y * v
      imaginary += x * v - y * u
    }
    guard denominator > 0 else { return nil }
    let a = real / denominator
    let b = imaginary / denominator
    guard a.isFinite, b.isFinite, a * a + b * b > 0 else { return nil }
    return CGAffineTransform(
      a: a, b: b, c: -b, d: a,
      tx: meanTarget.x - a * meanSource.x + b * meanSource.y,
      ty: meanTarget.y - b * meanSource.x - a * meanSource.y)
  }
}
