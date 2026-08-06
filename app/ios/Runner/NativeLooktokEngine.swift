import Flutter
import UIKit
import Vision

/// Native hot paths for the Dart `NativeLooktokEngine` (channel
/// `com.looktok.app/engine`). Contract (see NATIVE_ENGINE.md):
///  - isSegmentationSupported() -> Bool
///  - extractSilhouette(imagePath: String) -> String? path to a tight-cropped
///    transparent PNG in the temp dir; null/error -> Dart falls back.
///  - captureHighResPhoto() -> String? path to a JPEG (long side <=1600px);
///    null on cancel or when no camera is available.
class NativeLooktokEngine: NSObject {
  static let shared = NativeLooktokEngine()
  private var captureResult: FlutterResult?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.looktok.app/engine", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "isSegmentationSupported":
        result(true) // iOS 17+: subject mask; 15.5–16: person segmentation
      case "extractSilhouette":
        guard let args = call.arguments as? [String: Any],
              let path = args["imagePath"] as? String else {
          return result(FlutterError(code: "bad_args", message: "imagePath required", details: nil))
        }
        self.extractSilhouette(imagePath: path, result: result)
      case "captureHighResPhoto":
        self.captureHighResPhoto(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Silhouette extraction (Apple Vision)
  // iOS 17+: VNGenerateForegroundInstanceMaskRequest — best quality, ANY
  // salient subject (person or garment), tight-cropped by Vision itself.
  // iOS 15.5–16: VNGeneratePersonSegmentationRequest — person-only mask,
  // blended to transparency via CoreImage.

  private func extractSilhouette(imagePath: String, result: @escaping FlutterResult) {
    // Vision inference is heavy — never on the main/platform thread.
    DispatchQueue.global(qos: .userInitiated).async {
      let path: String?
      if #available(iOS 17.0, *) {
        path = Self.subjectMaskedPNG(imagePath: imagePath)
      } else {
        path = Self.personMaskedPNG(imagePath: imagePath)
      }
      DispatchQueue.main.async { result(path) } // nil → Dart falls back
    }
  }

  @available(iOS 17.0, *)
  private static func subjectMaskedPNG(imagePath: String) -> String? {
    do {
      let request = VNGenerateForegroundInstanceMaskRequest()
      let handler = VNImageRequestHandler(url: URL(fileURLWithPath: imagePath))
      try handler.perform([request])
      guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        return nil // no confident subject
      }
      // Crowd scenes: allInstances would cut out EVERY bystander around the
      // user. Pick the DOMINANT instance instead — the one with the largest
      // mask coverage (the person the photo is actually of).
      var instances = observation.allInstances
      if instances.count > 1 {
        let context = CIContext()
        var best: (index: Int, area: Double) = (instances.first!, -1)
        for index in instances {
          guard let mask = try? observation.generateScaledMaskForImage(
              forInstances: IndexSet(integer: index), from: handler) else { continue }
          let ci = CIImage(cvPixelBuffer: mask)
          // Mean of the mask ≈ fraction of frame covered by this instance.
          guard let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent),
          ]), let out = avgFilter.outputImage else { continue }
          var pixel = [UInt8](repeating: 0, count: 4)
          context.render(out, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
          let area = Double(pixel[0])
          if area > best.area { best = (index, area) }
        }
        instances = IndexSet(integer: best.index)
      }
      // Masked subject, tight-cropped to its extent, on transparent pixels.
      let buffer = try observation.generateMaskedImage(
        ofInstances: instances, from: handler, croppedToInstancesExtent: true)
      return writePNG(defringed(CIImage(cvPixelBuffer: buffer)))
    } catch {
      return nil
    }
  }

  private static func personMaskedPNG(imagePath: String) -> String? {
    do {
      let url = URL(fileURLWithPath: imagePath)
      guard let image = CIImage(contentsOf: url) else { return nil }
      let request = VNGeneratePersonSegmentationRequest()
      request.qualityLevel = .accurate
      request.outputPixelFormat = kCVPixelFormatType_OneComponent8
      let handler = VNImageRequestHandler(url: url)
      try handler.perform([request])
      guard let maskBuffer = request.results?.first?.pixelBuffer else { return nil }
      // Scale the mask up to the photo and knock the background out to alpha.
      var mask = CIImage(cvPixelBuffer: maskBuffer)
      mask = mask.transformed(by: CGAffineTransform(
        scaleX: image.extent.width / mask.extent.width,
        y: image.extent.height / mask.extent.height))
      let blend = CIFilter(name: "CIBlendWithMask", parameters: [
        kCIInputImageKey: image,
        kCIInputBackgroundImageKey: CIImage.empty().cropped(to: image.extent),
        kCIInputMaskImageKey: mask,
      ])
      guard let cutout = blend?.outputImage else { return nil }
      return writePNG(defringed(cutout))
    } catch {
      return nil
    }
  }

  /// Edge matting: Vision masks have hard 1px edges that carry the original
  /// background's color — a harsh white halo on dark UI. Erode the alpha
  /// ~1.5px (cuts the bleed ring off) then feather it slightly, and re-merge —
  /// the silhouette blends into dark backdrops instead of looking like a
  /// cardboard cutout.
  private static func defringed(_ image: CIImage) -> CIImage {
    // Alpha channel as a grayscale mask image (RGB = A, A = 1).
    let alphaMask = image.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    ])
    let refined = alphaMask
      .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5]) // erode
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])      // feather
      .cropped(to: image.extent)
    guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [
      kCIInputImageKey: image,
      kCIInputBackgroundImageKey: CIImage.empty().cropped(to: image.extent),
      kCIInputMaskImageKey: refined,
    ])?.outputImage else { return image }
    return blend.cropped(to: image.extent)
  }

  private static func writePNG(_ image: CIImage) -> String? {
    let context = CIContext()
    guard let png = context.pngRepresentation(
      of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
      return nil
    }
    let out = FileManager.default.temporaryDirectory
      .appendingPathComponent("looktok-seg-\(UUID().uuidString).png")
    do {
      try png.write(to: out)
      return out.path
    } catch {
      return nil
    }
  }

  // MARK: - Zero-lag native capture

  private func captureHighResPhoto(result: @escaping FlutterResult) {
    guard UIImagePickerController.isSourceTypeAvailable(.camera),
          captureResult == nil, // one capture at a time
          let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else {
      return result(nil)
    }
    captureResult = result
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = self
    root.present(picker, animated: true)
  }

  private func finishCapture(_ path: String?) {
    captureResult?(path)
    captureResult = nil
  }
}

extension NativeLooktokEngine: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage else { return finishCapture(nil) }
    // Long side <=1600px: sharp enough for segmentation + Gemini, small enough
    // that the raw-bytes fallback path never blows the base64 payload budget.
    let scaled = image.scaledDown(longSide: 1600)
    guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return finishCapture(nil) }
    let out = FileManager.default.temporaryDirectory
      .appendingPathComponent("looktok-cap-\(UUID().uuidString).jpg")
    do {
      try jpeg.write(to: out)
      finishCapture(out.path)
    } catch {
      finishCapture(nil)
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finishCapture(nil)
  }
}

private extension UIImage {
  func scaledDown(longSide: CGFloat) -> UIImage {
    let long = max(size.width, size.height)
    guard long > longSide else { return self }
    let scale = longSide / long
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }
  }
}
