import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

nonisolated protocol FaceRecognitionRepository: Sendable {
  func faces(in item: MediaItem) async throws -> [DetectedFace]
}

actor VisionFaceRecognitionRepository: FaceRecognitionRepository {
  private var model: MLModel?

  func faces(in item: MediaItem) async throws -> [DetectedFace] {
    try Task.checkCancellation()
    return try autoreleasepool {
      guard
        let source = CGImageSourceCreateWithURL(
          item.id.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw MediaRepositoryError.invalidPicture }
      let request = VNDetectFaceLandmarksRequest()
      try VNImageRequestHandler(cgImage: image).perform([request])
      // Stable left-to-right ordering gives faces in the same first photo distinct identities.
      let observations = (request.results ?? []).sorted {
        if $0.boundingBox.minX != $1.boundingBox.minX {
          return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return $0.boundingBox.minY > $1.boundingBox.minY
      }
      return try observations.compactMap { face in
        try Task.checkCancellation()
        guard let aligned = Self.alignedFace(face, in: image) else { return nil }
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
          thumbnail: MediaThumbnail(image: MediaImage(cgImage: aligned)))
      }
    }
  }

  private func recognitionModel() throws -> MLModel {
    if let model { return model }
    guard let url = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") else {
      throw PeopleRepositoryError.modelUnavailable
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let loaded = try MLModel(contentsOf: url, configuration: configuration)
    model = loaded
    return loaded
  }

  nonisolated private static func alignedFace(_ face: VNFaceObservation, in image: CGImage)
    -> CGImage?
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
    guard let transform = alignmentTransform(from: source, to: target),
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
