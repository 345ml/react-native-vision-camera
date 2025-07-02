//
//  CameraSession.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 11.10.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

/**
 A fully-featured Camera Session supporting preview, video, photo, frame processing, and code scanning outputs.
 All changes to the session have to be controlled via the `configure` function.
 */
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  // Configuration
  private var isInitialized = false
  var configuration: CameraConfiguration?
  var currentConfigureCall: DispatchTime = .now()
  // Capture Session
  let captureSession = AVCaptureSession()
  var multiCamSession: AVCaptureMultiCamSession?
  let audioCaptureSession = AVCaptureSession()
  // Inputs & Outputs
  var videoDeviceInput: AVCaptureDeviceInput?
  var secondaryVideoDeviceInput: AVCaptureDeviceInput?
  var audioDeviceInput: AVCaptureDeviceInput?
  var photoOutput: AVCapturePhotoOutput?
  var videoOutput: AVCaptureVideoDataOutput?
  var secondaryVideoOutput: AVCaptureVideoDataOutput?
  var audioOutput: AVCaptureAudioDataOutput?
  var codeScannerOutput: AVCaptureMetadataOutput?
  // State
  var metadataProvider = MetadataProvider()
  var recordingSession: RecordingSession?
  var didCancelRecording = false
  var orientationManager = OrientationManager()
  // PiP Video Mixing
  var pipVideoMixer: PiPVideoMixer?
  var primaryVideoBuffer: CVPixelBuffer?
  var secondaryVideoBuffer: CVPixelBuffer?
  var convertedPrimaryBuffer: CVPixelBuffer?
  var convertedSecondaryBuffer: CVPixelBuffer?

  // Callbacks
  weak var delegate: CameraSessionDelegate?

  // Public accessors
  var maxZoom: Double {
    if let device = videoDeviceInput?.device {
      return device.activeFormat.videoMaxZoomFactor
    }
    return 1.0
  }

  /**
   Create a new instance of the `CameraSession`.
   The `onError` callback is used for any runtime errors.
   */
  override init() {
    super.init()
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(sessionRuntimeError),
                                           name: .AVCaptureSessionRuntimeError,
                                           object: captureSession)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(sessionRuntimeError),
                                           name: .AVCaptureSessionRuntimeError,
                                           object: audioCaptureSession)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(audioSessionInterrupted),
                                           name: AVAudioSession.interruptionNotification,
                                           object: AVAudioSession.sharedInstance)
  }

  private func initialize() {
    if isInitialized {
      return
    }
    orientationManager.delegate = self
    isInitialized = true
  }

  deinit {
    NotificationCenter.default.removeObserver(self,
                                              name: .AVCaptureSessionRuntimeError,
                                              object: captureSession)
    NotificationCenter.default.removeObserver(self,
                                              name: .AVCaptureSessionRuntimeError,
                                              object: audioCaptureSession)
    NotificationCenter.default.removeObserver(self,
                                              name: AVAudioSession.interruptionNotification,
                                              object: AVAudioSession.sharedInstance)
  }

  /**
   Creates a PreviewView for the current Capture Session
   */
  func createPreviewView(frame: CGRect) -> UIView {
    if let multiCamSession = multiCamSession, isMultiCamActive {
      // Create multi-camera preview with PiP
      guard let primaryInput = videoDeviceInput,
            let secondaryInput = secondaryVideoDeviceInput else {
        return PreviewView(frame: frame, session: self.activeCaptureSession)
      }
      
      return MultiCamPreviewView(frame: frame, 
                                session: multiCamSession,
                                primaryPosition: primaryInput.device.position,
                                secondaryPosition: secondaryInput.device.position)
    } else {
      // Create regular single-camera preview
      return PreviewView(frame: frame, session: self.activeCaptureSession)
    }
  }

  func onConfigureError(_ error: Error) {
    if let error = error as? CameraError {
      // It's a typed Error
      delegate?.onError(error)
    } else {
      // It's any kind of unknown error
      let cameraError = CameraError.unknown(message: error.localizedDescription)
      delegate?.onError(cameraError)
    }
  }

  /**
   Update the session configuration.
   Any changes in here will be re-configured only if required, and under a lock (in this case, the serial cameraQueue DispatchQueue).
   The `configuration` object is a copy of the currently active configuration that can be modified by the caller in the lambda.
   */
  func configure(_ lambda: @escaping (_ configuration: CameraConfiguration) throws -> Void) {
    initialize()

    VisionLogger.log(level: .info, message: "configure { ... }: Waiting for lock...")

    // Set up Camera (Video) Capture Session (on camera queue, acts like a lock)
    CameraQueues.cameraQueue.async {
      // Let caller configure a new configuration for the Camera.
      let config = CameraConfiguration(copyOf: self.configuration)
      do {
        try lambda(config)
      } catch CameraConfiguration.AbortThrow.abort {
        // call has been aborted and changes shall be discarded
        return
      } catch {
        // another error occured, possibly while trying to parse enums
        self.onConfigureError(error)
        return
      }
      let difference = CameraConfiguration.Difference(between: self.configuration, and: config)

      VisionLogger.log(level: .info, message: "configure { ... }: Updating CameraSession Configuration... \(difference)")

      // Block ANY configuration changes during recording to prevent crashes
      if self.recordingSession != nil {
        VisionLogger.log(level: .error, message: "Cannot modify camera configuration while recording is active!")
        self.onConfigureError(CameraError.session(.cameraNotReady))
        return
      }

      do {
        // If needed, configure the AVCaptureSession (inputs, outputs)
        if difference.isSessionConfigurationDirty {
          // Check if we're switching to/from multi-camera mode
          let wasMultiCam = self.configuration?.secondaryCameraId != nil
          let isMultiCam = config.secondaryCameraId != nil
          
          if wasMultiCam != isMultiCam || (isMultiCam && difference.inputChanged) {
            // Check if recording is active before stopping session
            if self.recordingSession != nil {
              VisionLogger.log(level: .error, message: "Cannot reconfigure capture session while recording is active!")
              throw CameraError.session(.cameraNotReady)
            }
            
            // Need to reconfigure for multi-camera change
            if self.activeCaptureSession.isRunning {
              self.activeCaptureSession.stopRunning()
            }
          }
          
          // Begin configuration on the appropriate session
          if !isMultiCam && !wasMultiCam {
            self.captureSession.beginConfiguration()
          }

          // 1. Update input device
          if difference.inputChanged {
            if isMultiCam {
              try self.configureMultiCamera(configuration: config)
            } else {
              // When switching from multi-cam to single-cam, configureMultiCamera handles the transition
              if wasMultiCam {
                try self.configureMultiCamera(configuration: config)
              } else {
                try self.configureDevice(configuration: config)
              }
            }
          }
          // 2. Update outputs (only for single camera mode, multi-cam handles its own)
          if difference.outputsChanged && !isMultiCam && !wasMultiCam {
            try self.configureOutputs(configuration: config)
          }
          // 3. Update Video Stabilization
          if difference.videoStabilizationChanged && !isMultiCam {
            self.configureVideoStabilization(configuration: config)
          }
          // 4. Update target output orientation
          if difference.orientationChanged {
            self.orientationManager.setTargetOutputOrientation(config.outputOrientation)
          }
        }

        guard let device = self.videoDeviceInput?.device else {
          throw CameraError.device(.noDevice)
        }

        // If needed, configure the AVCaptureDevice (format, zoom, low-light-boost, ..)
        if difference.isDeviceConfigurationDirty {
          let isMultiCam = config.secondaryCameraId != nil
          
          try device.lockForConfiguration()
          defer {
            device.unlockForConfiguration()
          }

          // 5. Configure format (skip if in multi-camera mode as format is already configured)
          if difference.formatChanged && !isMultiCam {
            try self.configureFormat(configuration: config, device: device)
          }
          // 6. After step 2. and 4., we also need to configure some output properties that depend on format.
          //    This needs to be done AFTER we updated the `format`, as this controls the supported properties.
          if difference.outputsChanged || difference.formatChanged {
            self.configureVideoOutputFormat(configuration: config)
            self.configurePhotoOutputFormat(configuration: config)
          }
          // 7. Configure side-props (fps, lowLightBoost) - skip in multi-camera mode
          if difference.sidePropsChanged && !isMultiCam {
            try self.configureSideProps(configuration: config, device: device)
          }
          // 8. Configure zoom
          if difference.zoomChanged {
            self.configureZoom(configuration: config, device: device)
          }
          // 9. Configure exposure bias
          if difference.exposureChanged {
            self.configureExposure(configuration: config, device: device)
          }
        }

        if difference.isSessionConfigurationDirty {
          // We commit the session config updates AFTER the device config,
          // that way we can also batch those changes into one update instead of doing two updates.
          let wasMultiCam = self.configuration?.secondaryCameraId != nil
          let isMultiCam = config.secondaryCameraId != nil
          if !isMultiCam && !wasMultiCam {
            self.captureSession.commitConfiguration()
          }
        }

        // 10. Start or stop the session if needed
        self.checkIsActive(configuration: config)

        // 11. Enable or disable the Torch if needed (requires session to be running)
        if difference.torchChanged {
          try device.lockForConfiguration()
          defer {
            device.unlockForConfiguration()
          }
          try self.configureTorch(configuration: config, device: device)
        }

        // After configuring, set this to the new configuration.
        self.configuration = config
      } catch {
        self.onConfigureError(error)
      }

      // Set up Audio Capture Session (on audio queue)
      if difference.audioSessionChanged {
        CameraQueues.audioQueue.async {
          do {
            // Lock Capture Session for configuration
            VisionLogger.log(level: .info, message: "Beginning AudioSession configuration...")
            self.audioCaptureSession.beginConfiguration()

            try self.configureAudioSession(configuration: config)

            // Unlock Capture Session again and submit configuration to Hardware
            self.audioCaptureSession.commitConfiguration()
            VisionLogger.log(level: .info, message: "Committed AudioSession configuration!")
          } catch {
            self.onConfigureError(error)
          }
        }
      }

      // Set up Location streaming (on location queue)
      if difference.locationChanged {
        CameraQueues.locationQueue.async {
          do {
            VisionLogger.log(level: .info, message: "Beginning Location Output configuration...")
            try self.configureLocationOutput(configuration: config)
            VisionLogger.log(level: .info, message: "Finished Location Output configuration!")
          } catch {
            self.onConfigureError(error)
          }
        }
      }
    }
  }

  /**
   Starts or stops the CaptureSession if needed (`isActive`)
   */
  private func checkIsActive(configuration: CameraConfiguration) {
    let session = self.activeCaptureSession
    VisionLogger.log(level: .info, message: "checkIsActive: isActive=\(configuration.isActive), session.isRunning=\(session.isRunning), sessionType=\(type(of: session))")
    
    if configuration.isActive == session.isRunning {
      return
    }

    // Start/Stop session
    if configuration.isActive {
      // Protect against calling startRunning during configuration
      if session.isInterrupted {
        VisionLogger.log(level: .warning, message: "Session is interrupted, cannot start")
        return
      }
      
      VisionLogger.log(level: .info, message: "Starting capture session...")
      // Use dispatch to ensure we're not in a configuration block
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        let currentSession = self.activeCaptureSession
        if !currentSession.isRunning && configuration.isActive {
          currentSession.startRunning()
          self.delegate?.onCameraStarted()
        }
      }
    } else {
      VisionLogger.log(level: .info, message: "Stopping capture session...")
      session.stopRunning()
      delegate?.onCameraStopped()
    }
  }

  public final func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    switch captureOutput {
    case is AVCaptureVideoDataOutput:
      // Check if this is from primary or secondary video output for multi-camera
      if isMultiCamActive {
        if captureOutput === videoOutput {
          onPrimaryVideoFrame(sampleBuffer: sampleBuffer, orientation: connection.orientation, isMirrored: connection.isVideoMirrored)
        } else if captureOutput === secondaryVideoOutput {
          onSecondaryVideoFrame(sampleBuffer: sampleBuffer, orientation: connection.orientation, isMirrored: connection.isVideoMirrored)
        }
      } else {
        onVideoFrame(sampleBuffer: sampleBuffer, orientation: connection.orientation, isMirrored: connection.isVideoMirrored)
      }
    case is AVCaptureAudioDataOutput:
      onAudioFrame(sampleBuffer: sampleBuffer)
    default:
      break
    }
  }

  private final func onVideoFrame(sampleBuffer: CMSampleBuffer, orientation: Orientation, isMirrored: Bool) {
    if let recordingSession {
      do {
        // Write the Video Buffer to the .mov/.mp4 file
        try recordingSession.append(buffer: sampleBuffer, ofType: .video)
      } catch let error as CameraError {
        delegate?.onError(error)
      } catch {
        delegate?.onError(.capture(.unknown(message: error.localizedDescription)))
      }
    }

    if let delegate {
      // Call Frame Processor (delegate) for every Video Frame
      delegate.onFrame(sampleBuffer: sampleBuffer, orientation: orientation, isMirrored: isMirrored)
    }
  }
  
  private final func onPrimaryVideoFrame(sampleBuffer: CMSampleBuffer, orientation: Orientation, isMirrored: Bool) {
    // Store primary video buffer for PiP mixing
    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      primaryVideoBuffer = imageBuffer
      // Clear cached converted buffer when source changes
      convertedPrimaryBuffer = nil
    }
    
    // Try to mix with secondary buffer if available
    processPiPFrame(primaryBuffer: sampleBuffer, orientation: orientation, isMirrored: isMirrored)
    
    // Also call delegate for frame processing (original behavior)
    if let delegate {
      delegate.onFrame(sampleBuffer: sampleBuffer, orientation: orientation, isMirrored: isMirrored)
    }
  }
  
  private final func onSecondaryVideoFrame(sampleBuffer: CMSampleBuffer, orientation: Orientation, isMirrored: Bool) {
    // Store secondary video buffer for PiP mixing
    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      secondaryVideoBuffer = imageBuffer
      // Clear cached converted buffer when source changes
      convertedSecondaryBuffer = nil
    }
    
    // The mixing happens in primary frame processing
  }
  
  private final func processPiPFrame(primaryBuffer: CMSampleBuffer, orientation: Orientation, isMirrored: Bool) {
    guard let primaryPixelBuffer = primaryVideoBuffer,
          let secondaryPixelBuffer = secondaryVideoBuffer else {
      // If we don't have both buffers, record the primary buffer as-is
      if let recordingSession {
        do {
          try recordingSession.append(buffer: primaryBuffer, ofType: .video)
        } catch let error as CameraError {
          delegate?.onError(error)
        } catch {
          delegate?.onError(.capture(.unknown(message: error.localizedDescription)))
        }
      }
      return
    }
    
    // Initialize PiP mixer if needed
    if pipVideoMixer == nil {
      pipVideoMixer = PiPVideoMixer()
    }
    
    guard let mixer = pipVideoMixer else {
      print("Failed to create PiP mixer")
      return
    }
    
    // Prepare mixer if not already prepared
    if !mixer.isPrepared {
      if let formatDescription = CMSampleBufferGetFormatDescription(primaryBuffer) {
        mixer.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
      }
    }
    
    guard mixer.isPrepared else {
      print("PiP mixer not prepared")
      // Fallback to primary buffer recording
      if let recordingSession {
        do {
          try recordingSession.append(buffer: primaryBuffer, ofType: .video)
        } catch let error as CameraError {
          delegate?.onError(error)
        } catch {
          delegate?.onError(.capture(.unknown(message: error.localizedDescription)))
        }
      }
      return
    }
    
    // Update PiP frame to match preview configuration
    mixer.pipFrame = getNormalizedPiPFrame()
    
    // Mix the video frames
    if let mixedPixelBuffer = mixer.mix(fullScreenPixelBuffer: primaryPixelBuffer, 
                                       pipPixelBuffer: secondaryPixelBuffer) {
      
      // Create a new sample buffer with the mixed pixel buffer
      if let mixedSampleBuffer = createSampleBuffer(from: mixedPixelBuffer, 
                                                   timing: CMSampleBufferGetPresentationTimeStamp(primaryBuffer)) {
        
        // Write the mixed buffer to recording session
        if let recordingSession {
          do {
            try recordingSession.append(buffer: mixedSampleBuffer, ofType: .video)
          } catch let error as CameraError {
            delegate?.onError(error)
          } catch {
            delegate?.onError(.capture(.unknown(message: error.localizedDescription)))
          }
        }
      }
    } else {
      // Fallback to primary buffer if mixing fails
      if let recordingSession {
        do {
          try recordingSession.append(buffer: primaryBuffer, ofType: .video)
        } catch let error as CameraError {
          delegate?.onError(error)
        } catch {
          delegate?.onError(.capture(.unknown(message: error.localizedDescription)))
        }
      }
    }
  }
  
  private func getNormalizedPiPFrame() -> CGRect {
    // Calculate PiP size based on camera aspect ratio to maintain proper proportions
    let centerX: CGFloat = 0.85
    let centerY: CGFloat = 0.15
    let pipWidth: CGFloat = 0.25
    
    // Calculate height based on camera aspect ratio with height adjustment
    let cameraAspectRatio: CGFloat = getCameraAspectRatio()
    let baseHeight = pipWidth / cameraAspectRatio
    
    // Add 20% more height to match preview appearance
    let heightAdjustment: CGFloat = 1.20
    let pipHeight = baseHeight * heightAdjustment
    
    let topLeftX = centerX - pipWidth / 2
    let topLeftY = centerY - pipHeight / 2
    
    return CGRect(x: topLeftX, y: topLeftY, width: pipWidth, height: pipHeight)
  }
  
  private func getCameraAspectRatio() -> CGFloat {
    // Get aspect ratio from secondary camera format (PiP camera)
    guard let secondaryInput = secondaryVideoDeviceInput else {
      return 16.0 / 9.0 // Default to 16:9
    }
    
    let dimensions = CMVideoFormatDescriptionGetDimensions(secondaryInput.device.activeFormat.formatDescription)
    return CGFloat(dimensions.width) / CGFloat(dimensions.height)
  }
  
  private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, timing presentationTime: CMTime) -> CMSampleBuffer? {
    var sampleBuffer: CMSampleBuffer?
    var formatDescription: CMFormatDescription?
    
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription
    )
    
    guard status == noErr, let formatDesc = formatDescription else {
      print("Failed to create format description for mixed buffer. Status: \(status)")
      return nil
    }
    
    var timingInfo = CMSampleTimingInfo(
      duration: CMTime.invalid,
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: CMTime.invalid
    )
    
    // Create sample buffer with proper sample count
    let createStatus = CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDesc,
      sampleTiming: &timingInfo,
      sampleBufferOut: &sampleBuffer
    )
    
    guard createStatus == noErr else {
      print("Failed to create sample buffer from mixed pixel buffer. Status: \(createStatus)")
      return nil
    }
    
    return sampleBuffer
  }

  private final func onAudioFrame(sampleBuffer: CMSampleBuffer) {
    guard let recordingSession = recordingSession else {
      // No recording session active, skip audio frame
      return
    }
    
    do {
      // Synchronize the Audio Buffer with the Video Session's time because it's two separate
      // AVCaptureSessions, then write it to the .mov/.mp4 file
      audioCaptureSession.synchronizeBuffer(sampleBuffer, toSession: activeCaptureSession)
      try recordingSession.append(buffer: sampleBuffer, ofType: .audio)
    } catch let error as CameraError {
      VisionLogger.log(level: .error, message: "Audio frame processing error: \(error)")
      delegate?.onError(error)
    } catch {
      VisionLogger.log(level: .error, message: "Audio frame processing unknown error: \(error.localizedDescription)")
      delegate?.onError(.capture(.unknown(message: error.localizedDescription)))
    }
  }

  // pragma MARK: Notifications

  @objc
  func sessionRuntimeError(notification: Notification) {
    VisionLogger.log(level: .error, message: "Unexpected Camera Runtime Error occured!")
    guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
      return
    }

    VisionLogger.log(level: .error, message: "Session runtime error details: Code=\(error.code.rawValue), Description=\(error.localizedDescription)")

    // Handle specific error codes
    switch error.code.rawValue {
    case -11800:
      VisionLogger.log(level: .error, message: "Recording operation error - session may have been reconfigured during recording")
      // Don't restart session if recording is active - it will cause more errors
      if recordingSession != nil {
        VisionLogger.log(level: .error, message: "Skipping session restart due to active recording")
        delegate?.onError(.capture(.unknown(message: "Recording failed due to session error")))
        return
      }
    default:
      break
    }

    // Notify consumer about runtime error
    delegate?.onError(.unknown(message: error._nsError.description, cause: error._nsError))

    let shouldRestart = configuration?.isActive == true && recordingSession == nil
    if shouldRestart {
      // restart capture session after an error occured, but only if not recording
      CameraQueues.cameraQueue.async {
        // Add delay to ensure any ongoing configuration is completed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          // Restart the appropriate session (multi-cam or regular)
          if let multiCamSession = self.multiCamSession {
            // Only restart if session is not already running
            if !multiCamSession.isRunning {
              VisionLogger.log(level: .info, message: "Restarting multi-camera session after error")
              multiCamSession.startRunning()
            }
          } else {
            // Only restart if session is not already running
            if !self.captureSession.isRunning {
              VisionLogger.log(level: .info, message: "Restarting regular camera session after error")
              self.captureSession.startRunning()
            }
          }
        }
      }
    }
  }
}
