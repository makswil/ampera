import ARKit
import Accelerate
import AVFoundation
import CoreImage
import CoreML
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
        let args = call.arguments as? [String: Any]
        let hiRes = args?["hiRes"] as? Bool ?? false
        let lockAeAwb = args?["lockAeAwb"] as? Bool ?? true
        if hiRes {
          manager.captureHiResStill(lockAeAwb: lockAeAwb, result: result)
        } else {
          manager.captureStill(result: result)
        }
      case "previewFreeze":
        manager.previewFreezeJpeg(result: result)
      case "shareFiles":
        let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
        // Present on main; completion resolves the method channel so Dart isn't
        // left waiting and a stuck sheet can be dismissed cleanly.
        faceScanPresentShare(paths) {
          result(nil)
        }
      case "dismissPresented":
        // Unlock Flutter modals after a native share sheet (or other VC) sticks.
        DispatchQueue.main.async {
          guard let root = UIApplication.shared.faceScanKeyWindow?.rootViewController
          else {
            result(nil)
            return
          }
          if root.presentedViewController != nil {
            root.dismiss(animated: false) { result(nil) }
          } else {
            result(nil)
          }
        }
      case "correctWhiteBalance":
        // ml-wb CoreML white-balance on pose stills (before bake).
        // Args: jpegs: [FlutterStandardTypedData], matchFrontal: Bool,
        //       targetKelvin: Double? (default 5600 when matchFrontal=false).
        MLWhiteBalanceCorrector.shared.correct(call.arguments, result: result)
      case "configureOverlay":
        let args = call.arguments as? [String: Any]
        let show = args?["showMesh"] as? Bool ?? false
        let indices = (args?["axisIndices"] as? [NSNumber])?.map { $0.intValue } ?? []
        manager.configureOverlay(showMesh: show, axisIndices: indices)
        result(nil)
      case "openAppSettings":
        DispatchQueue.main.async {
          guard let url = URL(string: UIApplication.openSettingsURLString) else {
            result(nil)
            return
          }
          UIApplication.shared.open(url, options: [:]) { _ in
            result(nil)
          }
        }
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

  // The running ARKit configuration, kept so the session can be resumed after a
  // hi-res AVCapture photo (both need the TrueDepth camera, so ARKit is paused
  // for the shot and then re-run with the same config for continuity).
  private var arConfiguration: ARFaceTrackingConfiguration?

  // Separate front-camera photo session for the "AVCapture hi-res" texture
  // variant. Built lazily and reused; only running during a capture. `photoQueue`
  // serializes AVFoundation configuration / start / stop off the main thread.
  private var photoSession: AVCaptureSession?
  private var photoOutput: AVCapturePhotoOutput?
  private var photoDevice: AVCaptureDevice?
  private var activePhotoDelegate: PhotoCaptureDelegate?
  private let photoQueue = DispatchQueue(label: "flutter_face_scan.photo")

  /// ISO / shutter / WB from the first settled hi-res shot; reused when
  /// `lockAeAwb` is on so later poses don't re-auto and shift colour/exposure.
  private var lockedLook: LockedCameraLook?

  /// Fires once when the first ARFrame arrives after resume (or on timeout).
  private var onPreviewLive: (() -> Void)?

  private override init() {
    sceneView = ARSCNView(frame: .zero)
    super.init()
    sceneView.delegate = self
    sceneView.automaticallyUpdatesLighting = true
    sceneView.scene = SCNScene()
  }

  func start() {
    lockedLook = nil
    guard ARFaceTrackingConfiguration.isSupported else {
      eventSink?(FlutterError(
        code: "unsupported",
        message: "Face tracking (TrueDepth) is not supported on this device.",
        details: nil
      ))
      return
    }

    let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    switch cameraStatus {
    case .denied, .restricted:
      eventSink?(FlutterError(
        code: "permission",
        message: "Camera permission denied. Enable camera access in Settings.",
        details: nil
      ))
      return
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if granted {
            self.start()
          } else {
            self.eventSink?(FlutterError(
              code: "permission",
              message: "Camera permission denied. Enable camera access in Settings.",
              details: nil
            ))
          }
        }
      }
      return
    case .authorized:
      break
    @unknown default:
      break
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
    arConfiguration = configuration

    // Pre-warm the AVCapture photo camera BEFORE ARKit claims the TrueDepth
    // camera. The first-ever `startRunning` powers on the camera and can stall
    // for seconds; paying it once here means the first in-scan hi-res shot is as
    // fast as the later ones (no mid-scan freeze). ARKit is started only after
    // the warm-up releases the camera — a stopped-but-configured photo session
    // coexists with a running ARKit session.
    prewarmPhotoSession { [weak self] in
      guard let self = self else { return }
      self.sceneView.session.run(
        configuration,
        options: [.resetTracking, .removeExistingAnchors]
      )
      self.isRunning = true
      self.sentTopology = false
    }
  }

  func stop() {
    lockedLook = nil
    onPreviewLive = nil
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

  /// Pause ARKit, shoot a full-res AVCapture photo, resume. Returns ARKit
  /// registration matrices from the pre-pause frame plus the photo JPEG.
  /// Falls back to the ARKit video still from that same frame on failure.
  func captureHiResStill(lockAeAwb: Bool, result: @escaping FlutterResult) {
    guard let frame = sceneView.session.currentFrame,
          frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first != nil
    else {
      result(stillDict(from: sceneView.session.currentFrame))
      return
    }

    let fallback = stillDict(from: frame)

    let photoLandscape = frontPhotoResolution == .zero
      ? Self.maxFrontPhotoResolution()
      : frontPhotoResolution
    guard photoLandscape != .zero else { result(fallback); return }

    let portraitSize = CGSize(
      width: photoLandscape.height,
      height: photoLandscape.width
    )
    let view = flatten(frame.camera.viewMatrix(for: .portrait))
    let projection = flatten(frame.camera.projectionMatrix(
      for: .portrait,
      viewportSize: portraitSize,
      zNear: 0.001,
      zFar: 1000
    ))
    let faceTransform = flatten(
      frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first!.transform
    )
    logFovDiagnostics(frame)

    let shoot: () -> Void = { [weak self] in
      guard let self = self else {
        result(fallback)
        return
      }
      self.sceneView.session.pause()

      self.capturePhoto(lockAeAwb: lockAeAwb) { [weak self] ciImage in
        guard let self = self else {
          DispatchQueue.main.async { result(fallback) }
          return
        }

        let payload: [String: Any]? = {
          guard let ciImage = ciImage else { return nil }
          // Match ARKit portrait + un-mirror front-camera buffer.
          let portrait = ciImage.oriented(.right)
          let matched = portrait.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
          guard let cg = self.ciContext.createCGImage(matched, from: matched.extent),
                let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)
          else { return nil }
          return [
            "jpeg": FlutterStandardTypedData(bytes: jpeg),
            "width": cg.width,
            "height": cg.height,
            "viewMatrix": self.float32Data(view),
            "projectionMatrix": self.float32Data(projection),
            "faceTransform": self.float32Data(faceTransform),
          ]
        }()

        // Resolve only after the first live AR frame so Flutter can flip UI safely.
        DispatchQueue.main.async {
          self.resumeSession()
          self.whenPreviewLive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
              result(payload ?? fallback)
            }
          }
        }
      }
    }

    if Thread.isMainThread {
      shoot()
    } else {
      DispatchQueue.main.async(execute: shoot)
    }
  }

  /// JPEG of the live ARSCNView for Flutter's handoff cover.
  func previewFreezeJpeg(result: @escaping FlutterResult) {
    let deliver: () -> Void = { [weak self] in
      guard let self = self else {
        result(nil)
        return
      }
      let image = self.sceneView.snapshot()
      guard let data = image.jpegData(compressionQuality: 0.75) else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: data))
    }
    if Thread.isMainThread {
      deliver()
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }

  private func whenPreviewLive(_ block: @escaping () -> Void) {
    var done = false
    let fire: () -> Void = { [weak self] in
      guard !done else { return }
      done = true
      self?.onPreviewLive = nil
      block()
    }
    onPreviewLive = fire
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: fire)
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    onPreviewLive?()
  }

  /// Lazily builds/reuses the front-camera photo session, runs it, shoots one
  /// full-res photo and hands back its (sensor-oriented) `CIImage` — or nil on
  /// any failure. The session is stopped again before completion so the camera
  /// is released for ARKit to resume.
  ///
  /// When [lockAeAwb] is true: first shot settles auto AE/AWB then stores ISO /
  /// shutter / WB gains; later shots in this scan re-apply that locked look.
  private func capturePhoto(lockAeAwb: Bool, completion: @escaping (CIImage?) -> Void) {
    photoQueue.async { [weak self] in
      guard let self = self, self.ensurePhotoSession(),
            let session = self.photoSession, let output = self.photoOutput
      else {
        completion(nil)
        return
      }

      if !lockAeAwb {
        self.lockedLook = nil
      }

      if !session.isRunning { session.startRunning() }

      self.applyCameraLook(lockAeAwb: lockAeAwb)

      let settings = AVCapturePhotoSettings(format: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      ])
      if #available(iOS 16.0, *) {
        settings.maxPhotoDimensions = output.maxPhotoDimensions
      } else {
        settings.isHighResolutionPhotoEnabled = true
      }
      // Prefer our soft Flutter cue over the stock camera shutter (when allowed).
      if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
        settings.isShutterSoundSuppressionEnabled = true
      }

      let delegate = PhotoCaptureDelegate { [weak self] image in
        if session.isRunning { session.stopRunning() }
        self?.activePhotoDelegate = nil
        completion(image)
      }
      self.activePhotoDelegate = delegate
      output.capturePhoto(with: settings, delegate: delegate)
    }
  }

  /// Auto-settle then optionally snapshot/lock, or re-apply a prior lock.
  /// Must run on `photoQueue` with the photo session running.
  private func applyCameraLook(lockAeAwb: Bool) {
    guard let device = photoDevice else { return }

    if lockAeAwb, let look = lockedLook {
      applyLockedLook(look, on: device)
      // Brief settle after forcing custom modes (device may still be adjusting).
      Thread.sleep(forTimeInterval: 0.05)
      return
    }

    // Continuous auto + wait until AE/AWB finish adjusting.
    do {
      try device.lockForConfiguration()
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
        device.whiteBalanceMode = .continuousAutoWhiteBalance
      }
      device.unlockForConfiguration()
    } catch {
      NSLog("[face_scan] AE/AWB auto config failed: \(error)")
    }

    Thread.sleep(forTimeInterval: 0.1) // kick adjustment
    let deadline = Date().addingTimeInterval(0.8)
    while Date() < deadline,
          device.isAdjustingExposure || device.isAdjustingWhiteBalance {
      Thread.sleep(forTimeInterval: 0.03)
    }

    guard lockAeAwb else { return }

    // Snapshot settled values for later poses (usually after frontal).
    let iso = device.iso
    let duration = device.exposureDuration
    let gains = device.deviceWhiteBalanceGains
    lockedLook = LockedCameraLook(iso: iso, duration: duration, gains: gains)
    applyLockedLook(LockedCameraLook(iso: iso, duration: duration, gains: gains), on: device)
    NSLog(
      "[face_scan] AE/AWB locked iso=%.0f duration=%.4fs gains=r%.2f g%.2f b%.2f",
      iso,
      CMTimeGetSeconds(duration),
      gains.redGain, gains.greenGain, gains.blueGain
    )
  }

  private func applyLockedLook(_ look: LockedCameraLook, on device: AVCaptureDevice) {
    do {
      try device.lockForConfiguration()
      let format = device.activeFormat
      let iso = min(max(look.iso, format.minISO), format.maxISO)
      var duration = look.duration
      if CMTimeCompare(duration, format.minExposureDuration) < 0 {
        duration = format.minExposureDuration
      }
      if CMTimeCompare(duration, format.maxExposureDuration) > 0 {
        duration = format.maxExposureDuration
      }
      if device.isExposureModeSupported(.custom) {
        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
      }
      if device.isWhiteBalanceModeSupported(.locked) {
        let gains = clampWhiteBalanceGains(look.gains, on: device)
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
      }
      device.unlockForConfiguration()
    } catch {
      NSLog("[face_scan] AE/AWB lock apply failed: \(error)")
    }
  }

  private func clampWhiteBalanceGains(
    _ gains: AVCaptureDevice.WhiteBalanceGains,
    on device: AVCaptureDevice
  ) -> AVCaptureDevice.WhiteBalanceGains {
    let maxG = device.maxWhiteBalanceGain
    func clamp(_ v: Float) -> Float { min(maxG, max(1.0, v)) }
    return AVCaptureDevice.WhiteBalanceGains(
      redGain: clamp(gains.redGain),
      greenGain: clamp(gains.greenGain),
      blueGain: clamp(gains.blueGain)
    )
  }

  /// Powers on the photo camera once (configure + start + stop) so the first
  /// real hi-res capture doesn't pay the multi-second cold-start. Runs on
  /// `photoQueue`; invokes [completion] on the main thread when done (even on
  /// failure, so ARKit still starts).
  private func prewarmPhotoSession(completion: @escaping () -> Void) {
    photoQueue.async { [weak self] in
      if let self = self, self.ensurePhotoSession(), let session = self.photoSession {
        if !session.isRunning { session.startRunning() }
        if session.isRunning { session.stopRunning() }
      }
      DispatchQueue.main.async { completion() }
    }
  }

  /// Configures the front TrueDepth photo session once. Returns false if the
  /// device/input is unavailable. Must run on `photoQueue`.
  private func ensurePhotoSession() -> Bool {
    if photoSession != nil { return true }
    guard let device = AVCaptureDevice.default(
            .builtInTrueDepthCamera, for: .video, position: .front),
          let input = try? AVCaptureDeviceInput(device: device)
    else { return false }

    let session = AVCaptureSession()
    session.beginConfiguration()
    session.sessionPreset = .photo
    if session.canAddInput(input) { session.addInput(input) }

    let output = AVCapturePhotoOutput()
    if session.canAddOutput(output) { session.addOutput(output) }

    if #available(iOS 16.0, *) {
      if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
        Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
      }) {
        output.maxPhotoDimensions = maxDim
      }
    } else {
      output.isHighResolutionCaptureEnabled = true
    }

    // Match ARKit: no mirroring, raw sensor orientation (we orient in code).
    if let connection = output.connection(with: .video),
       connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = false
    }

    session.commitConfiguration()
    photoSession = session
    photoOutput = output
    photoDevice = device
    return true
  }

  /// Resumes the paused ARKit session with the stored config (no reset → keeps
  /// pose continuity across a hi-res shot).
  private func resumeSession() {
    guard let config = arConfiguration else { return }
    sceneView.session.run(config, options: [])
  }

  /// One-line log comparing ARKit's field of view against the AVCapture front
  /// format's, so a FOV/crop mismatch (the main registration risk) is verifiable
  /// on-device. Intrinsics-based correction is only needed if these diverge.
  private func logFovDiagnostics(_ frame: ARFrame) {
    let intr = frame.camera.intrinsics
    let res = frame.camera.imageResolution
    let arFovX = 2 * atan(Float(res.width) / (2 * intr.columns.0.x)) * 180 / .pi
    let avFovX = photoDevice?.activeFormat.videoFieldOfView
      ?? AVCaptureDevice.default(
        .builtInTrueDepthCamera, for: .video, position: .front
      )?.activeFormat.videoFieldOfView ?? 0
    NSLog("[face_scan] FOV check — ARKit hFOV=%.2f°  AVCapture hFOV=%.2f°", arFovX, avFovX)
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
      // Face-tracking rarely exposes AVDepthData; log availability for A/B.
      "hasDepth": frame.capturedDepthData != nil,
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
    // Always emit the expression keys we gate on (even at 0). ARKit may omit
    // near-zero coefficients from `faceAnchor.blendShapes`, which made the
    // smile gate see an empty map and reject a real smile.
    let tracked: [ARFaceAnchor.BlendShapeLocation] = [
      .jawOpen,
      .mouthSmileLeft, .mouthSmileRight,
      .mouthStretchLeft, .mouthStretchRight,
      .mouthPucker,
      .browInnerUp, .browDownLeft, .browDownRight,
      .eyeBlinkLeft, .eyeBlinkRight,
      .cheekPuff, .cheekSquintLeft, .cheekSquintRight,
      .noseSneerLeft, .noseSneerRight,
    ]
    for location in tracked {
      blendShapes[location.rawValue] =
        faceAnchor.blendShapes[location]?.doubleValue ?? 0
    }
    for (location, value) in faceAnchor.blendShapes {
      blendShapes[location.rawValue] = value.doubleValue
    }

    // Parallel typed-array path for expression gates. Nested `[String:Double]`
    // maps have been unreliable on the EventChannel next to large vertex
    // buffers; Float32List matches the vertices codec and is decoded first.
    // Order: smileL, smileR, stretchL, stretchR, squintL, squintR.
    let expressionCoeffs: [Float] = [
      Float(faceAnchor.blendShapes[.mouthSmileLeft]?.doubleValue ?? 0),
      Float(faceAnchor.blendShapes[.mouthSmileRight]?.doubleValue ?? 0),
      Float(faceAnchor.blendShapes[.mouthStretchLeft]?.doubleValue ?? 0),
      Float(faceAnchor.blendShapes[.mouthStretchRight]?.doubleValue ?? 0),
      Float(faceAnchor.blendShapes[.cheekSquintLeft]?.doubleValue ?? 0),
      Float(faceAnchor.blendShapes[.cheekSquintRight]?.doubleValue ?? 0),
    ]

    var result: [String: Any] = [
      "timestampMicros": Int(Date().timeIntervalSince1970 * 1_000_000),
      "isTracked": faceAnchor.isTracked,
      "transform": float32Data(flatten(faceAnchor.transform)),
      "vertices": float32Data(vertices),
      "blendShapes": blendShapes,
      "expressionCoeffs": float32Data(expressionCoeffs),
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

/// ISO + shutter + white-balance gains frozen after the first settled hi-res shot.
private struct LockedCameraLook {
  let iso: Float
  let duration: CMTime
  let gains: AVCaptureDevice.WhiteBalanceGains
}

/// One-shot `AVCapturePhotoCaptureDelegate` that forwards the captured photo as a
/// (sensor-oriented) `CIImage`, or nil on error. Kept alive by the manager for
/// the duration of the capture. We request an uncompressed BGRA buffer so the
/// raw pixels can be oriented identically to the ARKit still.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let completion: (CIImage?) -> Void

  init(completion: @escaping (CIImage?) -> Void) {
    self.completion = completion
    super.init()
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if error != nil {
      completion(nil)
      return
    }
    if let pixelBuffer = photo.pixelBuffer {
      completion(CIImage(cvPixelBuffer: pixelBuffer))
    } else if let data = photo.fileDataRepresentation(),
              let image = CIImage(data: data) {
      completion(image)
    } else {
      completion(nil)
    }
  }
}

/// Native share sheet for the given files (exports the baked model). No plugin,
/// keeps the SPM build clean.
///
/// [done] runs once the sheet is dismissed (share or cancel). Always called on
/// the main queue — even if presentation fails — so the Flutter method channel
/// never hangs and a subsequent share can re-present.
private func faceScanPresentShare(_ paths: [String], done: @escaping () -> Void) {
  DispatchQueue.main.async {
    let urls = paths
      .filter { FileManager.default.fileExists(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty,
          let root = faceScanTopViewController(
            UIApplication.shared.faceScanKeyWindow?.rootViewController)
    else {
      done()
      return
    }

    // Already showing a share sheet (or other modal) — dismiss it first so we
    // don't stack presentations (common cause of a frozen, undismissable sheet).
    if root.presentedViewController != nil {
      root.dismiss(animated: false) {
        faceScanPresentShareNow(from: root, urls: urls, done: done)
      }
      return
    }
    faceScanPresentShareNow(from: root, urls: urls, done: done)
  }
}

private func faceScanPresentShareNow(
  from root: UIViewController,
  urls: [URL],
  done: @escaping () -> Void
) {
  let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
  activity.completionWithItemsHandler = { _, _, _, _ in
    DispatchQueue.main.async { done() }
  }

  // iPad requires a popover anchor — without it, presenting crashes. Pin to the
  // top-trailing corner (where the Flutter share button lives) instead of the
  // screen centre; a centre popover with no arrow often eats the whole screen
  // and feels "stuck".
  if let popover = activity.popoverPresentationController {
    popover.sourceView = root.view
    let bounds = root.view.bounds
    let top = root.view.safeAreaInsets.top
    popover.sourceRect = CGRect(
      x: bounds.maxX - 44,
      y: top + 12,
      width: 32,
      height: 32
    )
    popover.permittedArrowDirections = [.up, .right]
  }

  root.present(activity, animated: true) {
    // If present somehow no-ops (already presenting), still unblock Dart.
    if root.presentedViewController !== activity {
      done()
    }
  }
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

// MARK: - ml-wb CoreML white-balance (on-device)

/// Ports `ml-wb/src/infer.py:correct_array` to CoreML: estimate Kelvin → delta →
/// U-Net@256 → per-pixel gain ratio upsampled to full res. Model lives in
/// `Runner/Models/MLWhiteBalance.mlpackage` (exported from the untouched ml-wb
/// checkpoint). Failures return the original JPEGs so bake never hard-fails.
///
/// Performance (no intentional quality trade-off): Accelerate vImage upsample,
/// direct MLMultiArray packing, Kelvin on 256px (same grid as the model), and
/// adaptive pose parallelism (4 / 2 / 1 by cores / RAM / thermal).
final class MLWhiteBalanceCorrector {
  static let shared = MLWhiteBalanceCorrector()

  private static let imageSize = 256
  private static let defaultKelvin: Float = 5600
  private static let kelvinMin: Float = 2700
  private static let kelvinMax: Float = 8500
  private static let deltaMin: Float = -5800
  private static let deltaMax: Float = 5800

  private let queue = DispatchQueue(label: "flutter_face_scan.ml_wb", qos: .userInitiated)
  private var model: MLModel?

  private init() {
    queue.async { [weak self] in
      self?.loadModelIfNeeded()
    }
  }

  func correct(_ arguments: Any?, result: @escaping FlutterResult) {
    queue.async {
      let out = self.correctSync(arguments)
      DispatchQueue.main.async { result(out) }
    }
  }

  private func correctSync(_ arguments: Any?) -> [String: Any] {
    let tBatch = CFAbsoluteTimeGetCurrent()
    guard let args = arguments as? [String: Any] else {
      return ["ok": false, "error": "bad args", "jpegs": [] as [Any]]
    }
    let rawJpegs = args["jpegs"] as? [Any] ?? []
    let datas: [Data] = rawJpegs.compactMap { item in
      if let t = item as? FlutterStandardTypedData { return t.data }
      if let d = item as? Data { return d }
      return nil
    }
    guard !datas.isEmpty else {
      return ["ok": false, "error": "no jpegs", "jpegs": [] as [Any]]
    }

    let matchFrontal = args["matchFrontal"] as? Bool ?? false
    var targetKelvin = Self.defaultKelvin
    if let t = args["targetKelvin"] as? Double {
      targetKelvin = Float(t)
    }

    var images: [CGImage] = []
    images.reserveCapacity(datas.count)
    var decodeMs: Double = 0
    for data in datas {
      let t0 = CFAbsoluteTimeGetCurrent()
      guard let img = self.cgImage(from: data) else {
        return [
          "ok": false,
          "error": "decode failed",
          "jpegs": datas.map { FlutterStandardTypedData(bytes: $0) },
        ]
      }
      decodeMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000
      images.append(img)
    }

    var kelvinMs: Double = 0
    if matchFrontal, let first = images.first {
      let t0 = CFAbsoluteTimeGetCurrent()
      // CCT on the same 256 grid the U-Net sees (not a quality downgrade of
      // the output JPEG — only the illuminant estimate).
      if let small = resizeCGImage(first, to: Self.imageSize),
         let rgba = rgbaBytes(small) {
        targetKelvin = estimateKelvin(
          rgba: rgba, width: Self.imageSize, height: Self.imageSize
        )
      } else {
        targetKelvin = estimateKelvin(first)
      }
      kelvinMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    guard loadModelIfNeeded() != nil else {
      return [
        "ok": false,
        "error": "model unavailable",
        "jpegs": datas.map { FlutterStandardTypedData(bytes: $0) },
      ]
    }

    let n = images.count
    let parallel = Self.mlWbParallelism()
    var outJpegs = [FlutterStandardTypedData?](repeating: nil, count: n)
    var sumPredict: Double = 0
    var sumApply: Double = 0
    var sumEncode: Double = 0
    var sumUpsample: Double = 0
    var sumRgba: Double = 0
    let lock = NSLock()

    let opQueue = OperationQueue()
    opQueue.name = "flutter_face_scan.ml_wb.poses"
    opQueue.maxConcurrentOperationCount = parallel
    let group = DispatchGroup()

    for i in 0..<n {
      group.enter()
      opQueue.addOperation { [weak self] in
        defer { group.leave() }
        guard let self else { return }
        let tPose = CFAbsoluteTimeGetCurrent()
        let cg = images[i]
        guard let corrected = self.correctImageTimed(cg, targetKelvin: targetKelvin)
        else {
          lock.lock()
          outJpegs[i] = FlutterStandardTypedData(bytes: datas[i])
          lock.unlock()
          return
        }
        let tEnc = CFAbsoluteTimeGetCurrent()
        // Keep prior JPEG quality — no end-product quality trade-off.
        guard let jpeg = self.jpegData(corrected.image, quality: 0.95) else {
          lock.lock()
          outJpegs[i] = FlutterStandardTypedData(bytes: datas[i])
          lock.unlock()
          return
        }
        let encMs = (CFAbsoluteTimeGetCurrent() - tEnc) * 1000
        var timing = corrected.timing
        timing["encode"] = encMs
        timing["poseTotal"] = (CFAbsoluteTimeGetCurrent() - tPose) * 1000
        lock.lock()
        outJpegs[i] = FlutterStandardTypedData(bytes: jpeg)
        sumPredict += timing["predict"] ?? 0
        sumApply += timing["apply"] ?? 0
        sumEncode += encMs
        sumUpsample += timing["upsample"] ?? 0
        sumRgba += timing["rgba"] ?? 0
        lock.unlock()
        NSLog(
          "[face_scan] ml-wb pose%d ms: rgba=%.0f kelvin=%.0f resize=%.0f pack=%.0f predict=%.0f ratio=%.0f upsample=%.0f apply=%.0f encode=%.0f total=%.0f (%dx%d)",
          i,
          timing["rgba"] ?? 0, timing["kelvin"] ?? 0, timing["resize"] ?? 0,
          timing["pack"] ?? 0, timing["predict"] ?? 0, timing["ratio"] ?? 0,
          timing["upsample"] ?? 0, timing["apply"] ?? 0, encMs,
          timing["poseTotal"] ?? 0, cg.width, cg.height
        )
      }
    }
    group.wait()
    opQueue.waitUntilAllOperationsAreFinished()

    let finalized: [FlutterStandardTypedData] = (0..<n).map { i in
      outJpegs[i] ?? FlutterStandardTypedData(bytes: datas[i])
    }
    let batchMs = (CFAbsoluteTimeGetCurrent() - tBatch) * 1000
    NSLog(
      "[face_scan] ml-wb BATCH ms: decode=%.0f kelvinRef=%.0f rgbaΣ=%.0f predictΣ=%.0f upsampleΣ=%.0f applyΣ=%.0f encodeΣ=%.0f total=%.0f poses=%d parallel=%d",
      decodeMs, kelvinMs, sumRgba, sumPredict, sumUpsample, sumApply, sumEncode,
      batchMs, n, parallel
    )
    return [
      "ok": true,
      "targetKelvin": Double(targetKelvin),
      "jpegs": finalized,
      "timingsMs": [
        "decode": decodeMs,
        "kelvinRef": kelvinMs,
        "rgbaSum": sumRgba,
        "predictSum": sumPredict,
        "upsampleSum": sumUpsample,
        "applySum": sumApply,
        "encodeSum": sumEncode,
        "batchTotal": batchMs,
        "poses": Double(n),
        "parallel": Double(parallel),
      ] as [String: Double],
    ]
  }

  /// 4 on strong devices, 2 on mid, 1 when hot / low-core / low-RAM.
  private static func mlWbParallelism() -> Int {
    let info = ProcessInfo.processInfo
    let cores = info.activeProcessorCount
    let gb = Double(info.physicalMemory) / 1_073_741_824.0
    let n: Int
    switch info.thermalState {
    case .critical, .serious:
      n = 1
    case .fair:
      n = cores >= 4 ? 2 : 1
    case .nominal:
      fallthrough
    @unknown default:
      if cores >= 6 && gb >= 5.5 {
        n = 4
      } else if cores >= 4 && gb >= 3.5 {
        n = 2
      } else {
        n = 1
      }
    }
    return max(1, min(4, min(n, min(cores, imagesCap(gb: gb)))))
  }

  private static func imagesCap(gb: Double) -> Int {
    if gb < 3.0 { return 1 }
    if gb < 4.5 { return 2 }
    return 4
  }

  @discardableResult
  private func loadModelIfNeeded() -> MLModel? {
    if let model { return model }
    let url =
      Bundle.main.url(forResource: "MLWhiteBalance", withExtension: "mlmodelc")
      ?? Bundle.main.url(forResource: "MLWhiteBalance", withExtension: "mlpackage")
    guard let url else {
      NSLog("[face_scan] MLWhiteBalance model not in bundle")
      return nil
    }
    do {
      let compiled: URL
      if url.pathExtension == "mlpackage" {
        compiled = try MLModel.compileModel(at: url)
      } else {
        compiled = url
      }
      let cfg = MLModelConfiguration()
      cfg.computeUnits = .all
      model = try MLModel(contentsOf: compiled, configuration: cfg)
      return model
    } catch {
      NSLog("[face_scan] MLWhiteBalance load failed: \(error)")
      return nil
    }
  }

  private struct CorrectedImage {
    let image: CGImage
    let timing: [String: Double]
  }

  private func correctImageTimed(_ cg: CGImage, targetKelvin: Float) -> CorrectedImage? {
    guard let model else { return nil }
    let w = cg.width
    let h = cg.height
    guard w > 0, h > 0 else { return nil }
    var timing: [String: Double] = [:]
    let size = Self.imageSize

    let tResize = CFAbsoluteTimeGetCurrent()
    guard let smallCG = resizeCGImage(cg, to: size),
          let resized = rgbaBytes(smallCG)
    else { return nil }
    timing["resize"] = (CFAbsoluteTimeGetCurrent() - tResize) * 1000

    let tKel = CFAbsoluteTimeGetCurrent()
    let kIn = estimateKelvin(rgba: resized, width: size, height: size)
    timing["kelvin"] = (CFAbsoluteTimeGetCurrent() - tKel) * 1000
    let delta = max(Self.deltaMin, min(Self.deltaMax, kIn - targetKelvin))

    let tPack = CFAbsoluteTimeGetCurrent()
    guard let imageArr = try? MLMultiArray(
      shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
      dataType: .float32
    ),
      let deltaArr = try? MLMultiArray(shape: [1], dataType: .float32)
    else { return nil }

    let plane = size * size
    let imgPtr = imageArr.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
    for i in 0..<plane {
      let src = i * 4
      imgPtr[i] = Float(resized[src]) / 255
      imgPtr[plane + i] = Float(resized[src + 1]) / 255
      imgPtr[2 * plane + i] = Float(resized[src + 2]) / 255
    }
    deltaArr[0] = NSNumber(value: delta)
    timing["pack"] = (CFAbsoluteTimeGetCurrent() - tPack) * 1000

    let provider: MLFeatureProvider
    do {
      provider = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(multiArray: imageArr),
        "delta": MLFeatureValue(multiArray: deltaArr),
      ])
    } catch {
      return nil
    }

    let tPred = CFAbsoluteTimeGetCurrent()
    guard let out = try? model.prediction(from: provider),
          let corrected = out.featureValue(for: "corrected")?.multiArrayValue
    else { return nil }
    timing["predict"] = (CFAbsoluteTimeGetCurrent() - tPred) * 1000

    let tRatio = CFAbsoluteTimeGetCurrent()
    var ratio = [Float](repeating: 1, count: 3 * plane)
    let corrPtr = corrected.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
    for c in 0..<3 {
      for i in 0..<plane {
        let inVal = Float(resized[i * 4 + c]) / 255 + 1e-6
        let outVal = corrPtr[c * plane + i]
        ratio[c * plane + i] = max(0.1, min(4.0, outVal / inVal))
      }
    }
    timing["ratio"] = (CFAbsoluteTimeGetCurrent() - tRatio) * 1000

    let tUp = CFAbsoluteTimeGetCurrent()
    guard let ratioFull = upsamplePlanarVImage(
      ratio, channels: 3, srcSize: size, dstW: w, dstH: h
    ) else { return nil }
    timing["upsample"] = (CFAbsoluteTimeGetCurrent() - tUp) * 1000

    let tRgba = CFAbsoluteTimeGetCurrent()
    guard var rgba = rgbaBytes(cg) else { return nil }
    timing["rgba"] = (CFAbsoluteTimeGetCurrent() - tRgba) * 1000

    let tApply = CFAbsoluteTimeGetCurrent()
    let fullPlane = w * h
    rgba.withUnsafeMutableBytes { raw in
      let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
      ratioFull.withUnsafeBufferPointer { ratioBuf in
        let rptr = ratioBuf.baseAddress!
        for i in 0..<fullPlane {
          let src = i * 4
          for c in 0..<3 {
            let v = Float(ptr[src + c]) * (1.0 / 255.0) * rptr[c * fullPlane + i]
            let clamped = min(255.0, max(0.0, v * 255.0))
            ptr[src + c] = UInt8(clamped)
          }
          ptr[src + 3] = 255
        }
      }
    }
    timing["apply"] = (CFAbsoluteTimeGetCurrent() - tApply) * 1000

    guard let outCg = cgImage(rgba: rgba, width: w, height: h) else { return nil }
    return CorrectedImage(image: outCg, timing: timing)
  }

  // MARK: - Kelvin (McCamy CCT from brightest ~5% pixels; matches ml-wb intent)

  private func estimateKelvin(_ cg: CGImage) -> Float {
    guard let rgba = rgbaBytes(cg) else { return Self.defaultKelvin }
    return estimateKelvin(rgba: rgba, width: cg.width, height: cg.height)
  }

  private func estimateKelvin(rgba: [UInt8], width: Int, height: Int) -> Float {
    let n = width * height
    guard n >= 10 else { return Self.defaultKelvin }
    var brightness = [Float](repeating: 0, count: n)
    for i in 0..<n {
      let o = i * 4
      brightness[i] =
        (Float(rgba[o]) + Float(rgba[o + 1]) + Float(rgba[o + 2])) / (3 * 255)
    }
    let sorted = brightness.sorted()
    let thresh = sorted[Int(Double(n) * 0.95)]
    var sr: Float = 0, sg: Float = 0, sb: Float = 0, count: Float = 0
    for i in 0..<n where brightness[i] >= thresh {
      let o = i * 4
      sr += Float(rgba[o]) / 255
      sg += Float(rgba[o + 1]) / 255
      sb += Float(rgba[o + 2]) / 255
      count += 1
    }
    guard count >= 10 else { return Self.defaultKelvin }

    let r = max(1e-6 as Float, pow(sr / count, 2.2))
    let g = max(1e-6 as Float, pow(sg / count, 2.2))
    let b = max(1e-6 as Float, pow(sb / count, 2.2))
    let x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
    let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
    let z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
    let sum = x + y + z
    guard sum > 1e-8 else { return Self.defaultKelvin }
    let cx = x / sum
    let cy = y / sum
    let nMc = (cx - 0.3320) / (0.1858 - cy)
    let cct = -449 * nMc * nMc * nMc + 3525 * nMc * nMc - 6823.3 * nMc + 5520.33
    return max(Self.kelvinMin, min(Self.kelvinMax, cct))
  }

  // MARK: - Image helpers

  private func cgImage(from jpeg: Data) -> CGImage? {
    guard let ui = UIImage(data: jpeg), let cg = ui.cgImage else { return nil }
    return cg
  }

  private func jpegData(_ cg: CGImage, quality: CGFloat) -> Data? {
    UIImage(cgImage: cg).jpegData(compressionQuality: quality)
  }

  private func rgbaBytes(_ cg: CGImage) -> [UInt8]? {
    let w = cg.width
    let h = cg.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
      data: &bytes,
      width: w,
      height: h,
      bitsPerComponent: 8,
      bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return bytes
  }

  private func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    var bytes = rgba
    guard let ctx = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let img = ctx.makeImage() else { return nil }
    return img
  }

  private func resizeCGImage(_ cg: CGImage, to size: Int) -> CGImage? {
    var out = [UInt8](repeating: 0, count: size * size * 4)
    guard let ctx = CGContext(
      data: &out,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
  }

  /// vImage high-quality bilinear upsample of planar CHW float.
  private func upsamplePlanarVImage(
    _ src: [Float], channels: Int, srcSize: Int, dstW: Int, dstH: Int
  ) -> [Float]? {
    let srcPlane = srcSize * srcSize
    let dstPlane = dstW * dstH
    var dst = [Float](repeating: 0, count: channels * dstPlane)
    var scratch = [Float](repeating: 0, count: srcPlane)
    for c in 0..<channels {
      for i in 0..<srcPlane {
        scratch[i] = src[c * srcPlane + i]
      }
      let ok: Bool = scratch.withUnsafeMutableBufferPointer { sBuf in
        dst.withUnsafeMutableBufferPointer { dBuf in
          var srcBuf = vImage_Buffer(
            data: sBuf.baseAddress,
            height: vImagePixelCount(srcSize),
            width: vImagePixelCount(srcSize),
            rowBytes: srcSize * MemoryLayout<Float>.size
          )
          var dstBuf = vImage_Buffer(
            data: dBuf.baseAddress!.advanced(by: c * dstPlane),
            height: vImagePixelCount(dstH),
            width: vImagePixelCount(dstW),
            rowBytes: dstW * MemoryLayout<Float>.size
          )
          let err = vImageScale_PlanarF(
            &srcBuf,
            &dstBuf,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
          )
          return err == kvImageNoError
        }
      }
      if !ok { return nil }
    }
    return dst
  }
}
