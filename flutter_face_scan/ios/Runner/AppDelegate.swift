import ARKit
import AVFoundation
import CoreImage
import Flutter
import SceneKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    if let registrar = registry.registrar(forPlugin: "FaceTrackingPlugin") {
      FaceTrackingPlugin.register(with: registrar)
    }
  }
}

// MARK: - TrueDepth face tracking
//
// NOTE: this code lives in AppDelegate.swift (already part of the Runner build
// target) on purpose, so no Xcode "Target Membership" step is needed. It can be
// split back into ios/Runner/FaceTracking/*.swift later if those files are added
// to the Runner target in Build Phases → Compile Sources.

/// Registers the TrueDepth face-tracking channels and preview platform view.
///
/// Channel names mirror `ArkitFaceTrackingService` on the Dart side:
///   * method  `flutter_face_scan/face_tracking`         — start / stop
///   * event   `flutter_face_scan/face_tracking/frames`  — per-frame payloads
///   * view    `flutter_face_scan/face_preview`          — live ARSCNView
enum FaceTrackingPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let manager = FaceTrackingManager.shared
    let messenger = registrar.messenger()

    let control = FlutterMethodChannel(
      name: "flutter_face_scan/face_tracking",
      binaryMessenger: messenger
    )
    control.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        manager.start()
        result(nil)
      case "stop":
        manager.stop()
        result(nil)
      case "captureStill":
        manager.captureStill(result: result)
      case "shareFiles":
        let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
        faceScanPresentShare(paths)
        result(nil)
      case "configureOverlay":
        let args = call.arguments as? [String: Any]
        let show = args?["showMesh"] as? Bool ?? false
        let indices = (args?["axisIndices"] as? [NSNumber])?.map { $0.intValue } ?? []
        manager.configureOverlay(showMesh: show, axisIndices: indices)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let frames = FlutterEventChannel(
      name: "flutter_face_scan/face_tracking/frames",
      binaryMessenger: messenger
    )
    frames.setStreamHandler(manager)

    registrar.register(
      FacePreviewFactory(),
      withId: "flutter_face_scan/face_preview"
    )
  }
}

/// Owns the single `ARFaceTrackingConfiguration` session and bridges its
/// per-frame `ARFaceAnchor` data (vertices + blendshapes + transform) to Flutter.
final class FaceTrackingManager: NSObject, ARSCNViewDelegate, FlutterStreamHandler {
  static let shared = FaceTrackingManager()

  let sceneView: ARSCNView
  private var eventSink: FlutterEventSink?
  private var isRunning = false

  // Verification overlay state (driven from Dart via `configureOverlay`).
  private var showMesh = false
  private var axisIndices: [Int] = []
  private var axisNodes: [SCNNode] = []

  // The face-mesh triangle topology is constant; send it once per session.
  private var sentTopology = false

  // Whether the session can grab a hi-res still via captureHighResolutionFrame.
  private var supportsHiResCapture = false

  // Configured video-format resolution (landscape sensor px) — for the HUD.
  private var captureResolution: CGSize = .zero

  // Front camera's max still-photo resolution (what AVCapturePhoto could give) —
  // for the HUD, to show the gap vs. the ARKit video feed.
  private var frontPhotoResolution: CGSize = .zero

  private let ciContext = CIContext()

  private override init() {
    sceneView = ARSCNView(frame: .zero)
    super.init()
    sceneView.delegate = self
    sceneView.automaticallyUpdatesLighting = true
    sceneView.scene = SCNScene()
  }

  func start() {
    guard ARFaceTrackingConfiguration.isSupported else {
      eventSink?(FlutterError(
        code: "unsupported",
        message: "Face tracking (TrueDepth) is not supported on this device.",
        details: nil
      ))
      return
    }
    let configuration = ARFaceTrackingConfiguration()
    configuration.maximumNumberOfTrackedFaces = 1
    configuration.isLightEstimationEnabled = false
    // Prefer a format that supports hi-res frame capture (sharper stills). Try
    // the recommended one, else any format flagged for it; fall back to the
    // highest-resolution video format.
    supportsHiResCapture = false
    if #available(iOS 16.0, *) {
      let hiRes = ARFaceTrackingConfiguration
        .recommendedVideoFormatForHighResolutionFrameCapturing
        ?? ARFaceTrackingConfiguration.supportedVideoFormats
          .first(where: { $0.isRecommendedForHighResolutionFrameCapturing })
      if let hiRes = hiRes {
        configuration.videoFormat = hiRes
        supportsHiResCapture = true
      }
    }
    if !supportsHiResCapture,
       let best = ARFaceTrackingConfiguration.supportedVideoFormats.max(by: {
         $0.imageResolution.width * $0.imageResolution.height
           < $1.imageResolution.width * $1.imageResolution.height
       }) {
      configuration.videoFormat = best
    }
    captureResolution = configuration.videoFormat.imageResolution
    frontPhotoResolution = Self.maxFrontPhotoResolution()
    sceneView.session.run(
      configuration,
      options: [.resetTracking, .removeExistingAnchors]
    )
    isRunning = true
    sentTopology = false
  }

  func stop() {
    sceneView.session.pause()
    isRunning = false
    sentTopology = false
  }

  /// Max still-photo resolution of the TrueDepth front camera (read-only query,
  /// no session). Shows how much the ARKit face-video feed leaves on the table.
  private static func maxFrontPhotoResolution() -> CGSize {
    guard let device = AVCaptureDevice.default(
      .builtInTrueDepthCamera, for: .video, position: .front
    ) else { return .zero }
    var best = CGSize.zero
    for format in device.formats {
      var w = 0
      var h = 0
      if #available(iOS 16.0, *),
         let dim = format.supportedMaxPhotoDimensions.max(by: {
           Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
         }) {
        w = Int(dim.width); h = Int(dim.height)
      } else {
        let dim = format.highResolutionStillImageDimensions
        w = Int(dim.width); h = Int(dim.height)
      }
      if w * h > Int(best.width) * Int(best.height) {
        best = CGSize(width: w, height: h)
      }
    }
    return best
  }

  /// Async so it can grab a HI-RES still via `captureHighResolutionFrame` (from
  /// the running ARKit session) when supported; falls back to the current
  /// video-res frame otherwise. Passes the still map (or nil) to [result].
  func captureStill(result: @escaping FlutterResult) {
    if #available(iOS 16.0, *), supportsHiResCapture {
      sceneView.session.captureHighResolutionFrame { [weak self] frame, error in
        guard let self = self else { result(nil); return }
        let dict = (frame != nil && error == nil)
          ? self.stillDict(from: frame)
          : self.stillDict(from: self.sceneView.session.currentFrame)
        // Completion may run off the main thread; FlutterResult must be on main.
        DispatchQueue.main.async { result(dict) }
      }
    } else {
      result(stillDict(from: sceneView.session.currentFrame))
    }
  }

  /// Portrait JPEG + the projection into it, all from one [frame] (so pixels and
  /// matrices agree). Nil if no frame / no tracked face. Map: `jpeg`, `width`,
  /// `height`, `viewMatrix`, `projectionMatrix`, `faceTransform` (matrices
  /// 16-float column-major). `.oriented(.right)` matches `.portrait`.
  private func stillDict(from frame: ARFrame?) -> [String: Any]? {
    guard let frame = frame,
          let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first
    else { return nil }

    let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
    guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent),
          let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
    else {
      return nil
    }

    let width = cgImage.width
    let height = cgImage.height
    let viewport = CGSize(width: width, height: height)
    let view = frame.camera.viewMatrix(for: .portrait)
    let projection = frame.camera.projectionMatrix(
      for: .portrait,
      viewportSize: viewport,
      zNear: 0.001,
      zFar: 1000
    )

    return [
      "jpeg": FlutterStandardTypedData(bytes: jpeg),
      "width": width,
      "height": height,
      "viewMatrix": float32Data(flatten(view)),
      "projectionMatrix": float32Data(flatten(projection)),
      "faceTransform": float32Data(flatten(faceAnchor.transform)),
    ]
  }

  /// Enables/disables the live verification overlay. `axisIndices` is supplied
  /// by Dart (`FaceSymmetryAxis.ordered`) so the rendered red midline reflects
  /// the exact index table the Dart logic uses — i.e. this visually verifies it.
  func configureOverlay(showMesh: Bool, axisIndices: [Int]) {
    self.showMesh = showMesh
    self.axisIndices = axisIndices
    axisNodes.forEach { $0.removeFromParentNode() }
    axisNodes.removeAll()
  }

  func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
    if let faceAnchor = anchor as? ARFaceAnchor {
      applyOverlay(to: node, faceAnchor: faceAnchor)
    }
    emit(anchor)
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    if let faceAnchor = anchor as? ARFaceAnchor {
      applyOverlay(to: node, faceAnchor: faceAnchor)
    }
    emit(anchor)
  }

  /// Green wireframe of the full TrueDepth mesh + red dots on the symmetry-axis
  /// vertices, reconciled every frame from the current flags.
  private func applyOverlay(to node: SCNNode, faceAnchor: ARFaceAnchor) {
    guard showMesh else {
      if node.geometry is ARSCNFaceGeometry { node.geometry = nil }
      axisNodes.forEach { $0.removeFromParentNode() }
      axisNodes.removeAll()
      return
    }

    // Full face mesh as a green wireframe.
    if let faceGeometry = node.geometry as? ARSCNFaceGeometry {
      faceGeometry.update(from: faceAnchor.geometry)
    } else if let device = sceneView.device,
              let faceGeometry = ARSCNFaceGeometry(device: device) {
      faceGeometry.firstMaterial?.fillMode = .lines
      faceGeometry.firstMaterial?.diffuse.contents = UIColor.systemGreen
      faceGeometry.firstMaterial?.lightingModel = .constant
      faceGeometry.update(from: faceAnchor.geometry)
      node.geometry = faceGeometry
    }

    // Symmetry-axis vertices as red dots (rebuilt lazily after a config change).
    let vertices = faceAnchor.geometry.vertices
    if axisNodes.isEmpty && !axisIndices.isEmpty {
      for _ in axisIndices {
        let sphere = SCNSphere(radius: 0.0022)
        sphere.firstMaterial?.diffuse.contents = UIColor.systemRed
        sphere.firstMaterial?.lightingModel = .constant
        let dot = SCNNode(geometry: sphere)
        node.addChildNode(dot)
        axisNodes.append(dot)
      }
    }
    for (i, index) in axisIndices.enumerated() {
      guard index >= 0, index < vertices.count, i < axisNodes.count else { continue }
      let v = vertices[index]
      axisNodes[i].simdPosition = simd_float3(v.x, v.y, v.z)
    }
  }

  private func emit(_ anchor: ARAnchor) {
    guard isRunning,
          let faceAnchor = anchor as? ARFaceAnchor,
          let sink = eventSink else { return }
    sink(payload(from: faceAnchor))
  }

  private func payload(from faceAnchor: ARFaceAnchor) -> [String: Any] {
    let geometry = faceAnchor.geometry

    var vertices = [Float]()
    vertices.reserveCapacity(geometry.vertices.count * 3)
    for vertex in geometry.vertices {
      vertices.append(vertex.x)
      vertices.append(vertex.y)
      vertices.append(vertex.z)
    }

    var blendShapes = [String: Double]()
    for (location, value) in faceAnchor.blendShapes {
      blendShapes[location.rawValue] = value.doubleValue
    }

    var result: [String: Any] = [
      "timestampMicros": Int(Date().timeIntervalSince1970 * 1_000_000),
      "isTracked": faceAnchor.isTracked,
      "transform": float32Data(flatten(faceAnchor.transform)),
      "vertices": float32Data(vertices),
      "blendShapes": blendShapes,
    ]

    // Camera transform (for camera-relative Euler) + the symmetry-axis vertices
    // projected to normalized screen space (for the 2D "facing camera" gate).
    if let camera = sceneView.session.currentFrame?.camera {
      result["cameraTransform"] = float32Data(flatten(camera.transform))
      if !axisIndices.isEmpty {
        let viewport = sceneView.bounds.size
        let faceT = faceAnchor.transform
        var screenPoints = [Float]()
        screenPoints.reserveCapacity(axisIndices.count * 2)
        for index in axisIndices where index >= 0 && index < geometry.vertices.count {
          let v = geometry.vertices[index]
          let world = faceT * simd_float4(v.x, v.y, v.z, 1)
          let projected = camera.projectPoint(
            simd_float3(world.x, world.y, world.z),
            orientation: .portrait,
            viewportSize: viewport
          )
          let nx = viewport.width > 0 ? Float(projected.x / viewport.width) : 0
          let ny = viewport.height > 0 ? Float(projected.y / viewport.height) : 0
          screenPoints.append(nx)
          screenPoints.append(ny)
        }
        result["axisScreenPoints"] = float32Data(screenPoints)
      }
    }

    // Triangle topology AND texture coordinates are constant — emit once per
    // session so Dart can cache them (PLY faces / V3 reconstruction / UV baking).
    if !sentTopology {
      let indices = geometry.triangleIndices.map { Int32($0) }
      result["triangleIndices"] = int32Data(indices)

      // Per-vertex UVs (ARKit atlas), flat [u0,v0, u1,v1, …].
      var uvs = [Float]()
      uvs.reserveCapacity(geometry.textureCoordinates.count * 2)
      for uv in geometry.textureCoordinates {
        uvs.append(uv.x)
        uvs.append(uv.y)
      }
      result["textureCoordinates"] = float32Data(uvs)

      // Hi-res capture flag + video + max photo resolution (HUD readout).
      result["hiResCapture"] = supportsHiResCapture
      result["captureWidth"] = Int(captureResolution.width)
      result["captureHeight"] = Int(captureResolution.height)
      result["photoWidth"] = Int(frontPhotoResolution.width)
      result["photoHeight"] = Int(frontPhotoResolution.height)

      sentTopology = true
    }

    return result
  }

  /// Column-major flatten to match `vector_math` `Matrix4.fromList`.
  private func flatten(_ m: simd_float4x4) -> [Float] {
    return [
      m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
      m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
      m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
      m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
    ]
  }

  private func float32Data(_ values: [Float]) -> FlutterStandardTypedData {
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    return FlutterStandardTypedData(float32: data)
  }

  private func int32Data(_ values: [Int32]) -> FlutterStandardTypedData {
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    return FlutterStandardTypedData(int32: data)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

/// Native share sheet for the given files (exports the baked model). No plugin,
/// keeps the SPM build clean.
private func faceScanPresentShare(_ paths: [String]) {
  let urls = paths
    .filter { FileManager.default.fileExists(atPath: $0) }
    .map { URL(fileURLWithPath: $0) }
  guard !urls.isEmpty,
        let root = faceScanTopViewController(UIApplication.shared.faceScanKeyWindow?.rootViewController)
  else { return }

  let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
  // iPad requires a popover anchor — without it, presenting crashes.
  if let popover = activity.popoverPresentationController {
    popover.sourceView = root.view
    popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
    popover.permittedArrowDirections = []
  }
  root.present(activity, animated: true)
}

/// Deepest presented view controller, so the share sheet attaches to whatever is
/// on screen (Flutter view, a modal, etc.).
private func faceScanTopViewController(_ base: UIViewController?) -> UIViewController? {
  guard let base = base else { return nil }
  if let presented = base.presentedViewController {
    return faceScanTopViewController(presented)
  }
  if let nav = base as? UINavigationController {
    return faceScanTopViewController(nav.visibleViewController)
  }
  if let tab = base as? UITabBarController {
    return faceScanTopViewController(tab.selectedViewController)
  }
  return base
}

private extension UIApplication {
  /// The active key window across connected scenes.
  var faceScanKeyWindow: UIWindow? {
    connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }
}

/// Exposes the shared ARKit `ARSCNView` to Flutter as a `UiKitView`.
final class FacePreviewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return FacePreviewView(frame: frame)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

final class FacePreviewView: NSObject, FlutterPlatformView {
  private let sceneView = FaceTrackingManager.shared.sceneView

  init(frame: CGRect) {
    super.init()
    sceneView.frame = frame
  }

  func view() -> UIView {
    return sceneView
  }
}
