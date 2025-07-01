//
//  CameraSession+MultiCam.swift
//  VisionCamera
//
//  Created by Claude Code on 25.06.25.
//  Copyright © 2025 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation
import UIKit

extension CameraSession {
  
  /**
   Configures multi-camera functionality with primary and secondary devices
   */
  func configureMultiCamera(configuration: CameraConfiguration) throws {
    VisionLogger.log(level: .info, message: "Configuring Multi-Camera...")
    
    guard let secondaryCameraId = configuration.secondaryCameraId else {
      // No secondary camera, use regular session
      try configureSingleCamera(configuration: configuration)
      return
    }
    
    guard #available(iOS 13.0, *) else {
      throw CameraError.device(.notAvailableOnSimulator)
    }
    
    guard AVCaptureMultiCamSession.isMultiCamSupported else {
      VisionLogger.log(level: .error, message: "Multi-camera not supported on this device")
      throw CameraError.parameter(.unsupportedInput(inputDescriptor: "multi-cam-session"))
    }
    
    // Initialize multi-cam session if needed
    if multiCamSession == nil {
      multiCamSession = AVCaptureMultiCamSession()
      
      // Remove all observers from the old session
      NotificationCenter.default.removeObserver(self,
                                                name: .AVCaptureSessionRuntimeError,
                                                object: captureSession)
      
      // Add observers to the new multi-cam session
      NotificationCenter.default.addObserver(self,
                                             selector: #selector(sessionRuntimeError),
                                             name: .AVCaptureSessionRuntimeError,
                                             object: multiCamSession)
    }
    
    guard let multiCamSession = self.multiCamSession else {
      throw CameraError.parameter(.unsupportedInput(inputDescriptor: "multi-cam-session"))
    }
    
    // Remove all existing inputs and outputs
    for input in multiCamSession.inputs {
      multiCamSession.removeInput(input)
    }
    for output in multiCamSession.outputs {
      multiCamSession.removeOutput(output)
    }
    
    // Reset device inputs
    videoDeviceInput = nil
    secondaryVideoDeviceInput = nil
    photoOutput = nil
    videoOutput = nil
    secondaryVideoOutput = nil
    codeScannerOutput = nil
    
    multiCamSession.beginConfiguration()
    defer {
      multiCamSession.commitConfiguration()
    }
    
    // Configure primary camera
    try configurePrimaryCamera(session: multiCamSession, configuration: configuration)
    
    // Configure secondary camera
    try configureSecondaryCamera(session: multiCamSession, configuration: configuration)
    
    VisionLogger.log(level: .info, message: "Successfully configured Multi-Camera!")
    
    // Notify delegate that session is initialized
    delegate?.onSessionInitialized()
  }
  
  private func configureSingleCamera(configuration: CameraConfiguration) throws {
    VisionLogger.log(level: .info, message: "Switching to single camera mode...")
    
    // Reset multi-cam session if it was active
    let wasMultiCam = multiCamSession != nil
    if let multiCamSession = multiCamSession {
      // Stop and clean up multi-cam session
      if multiCamSession.isRunning {
        multiCamSession.stopRunning()
      }
      
      // Remove all inputs and outputs from multi-cam session
      for input in multiCamSession.inputs {
        multiCamSession.removeInput(input)
      }
      for output in multiCamSession.outputs {
        multiCamSession.removeOutput(output)
      }
      
      // Clear the multi-cam session reference
      self.multiCamSession = nil
    }
    
    // If we're switching from multi-cam to single-cam, reset device format and clean up PiP resources
    if wasMultiCam {
      // Clean up PiP mixer resources
      pipVideoMixer?.reset()
      pipVideoMixer = nil
      primaryVideoBuffer = nil
      secondaryVideoBuffer = nil
      convertedPrimaryBuffer = nil
      convertedSecondaryBuffer = nil
      
      // Reset inputs and outputs
      videoDeviceInput = nil
      secondaryVideoDeviceInput = nil
      photoOutput = nil
      videoOutput = nil
      secondaryVideoOutput = nil
      codeScannerOutput = nil
      
      if let cameraId = configuration.cameraId,
         let videoDevice = AVCaptureDevice(uniqueID: cameraId) {
        VisionLogger.log(level: .info, message: "Resetting device format after multi-cam switch...")
        try resetDeviceFormatToDefault(device: videoDevice)
      }
      
      // Begin configuration on single camera session
      captureSession.beginConfiguration()
      defer {
        captureSession.commitConfiguration()
      }
    }
    
    // Use the existing single camera configuration
    try configureDevice(configuration: configuration)
    try configureOutputs(configuration: configuration)
  }
  
  private func configurePrimaryCamera(session: AVCaptureMultiCamSession, configuration: CameraConfiguration) throws {
    guard let cameraId = configuration.cameraId else {
      throw CameraError.device(.noDevice)
    }
    
    VisionLogger.log(level: .info, message: "Configuring Primary Camera \(cameraId)...")
    
    guard let videoDevice = AVCaptureDevice(uniqueID: cameraId) else {
      throw CameraError.device(.invalid)
    }
    
    // Set a multi-camera compatible format before adding the input
    if #available(iOS 13.0, *) {
      try configureMultiCamFormat(device: videoDevice)
    }
    
    let input = try AVCaptureDeviceInput(device: videoDevice)
    guard session.canAddInput(input) else {
      throw CameraError.parameter(.unsupportedInput(inputDescriptor: "primary-video-input"))
    }
    session.addInputWithNoConnections(input)
    videoDeviceInput = input
    
    // Configure primary camera outputs
    try configurePrimaryCameraOutputs(session: session, configuration: configuration, videoDevice: videoDevice)
    
    // Update Orientation manager
    orientationManager.setInputDevice(videoDevice)
  }
  
  private func configureSecondaryCamera(session: AVCaptureMultiCamSession, configuration: CameraConfiguration) throws {
    guard let secondaryCameraId = configuration.secondaryCameraId else {
      return
    }
    
    VisionLogger.log(level: .info, message: "Configuring Secondary Camera \(secondaryCameraId)...")
    
    guard let secondaryVideoDevice = AVCaptureDevice(uniqueID: secondaryCameraId) else {
      throw CameraError.device(.invalid)
    }
    
    // Set a multi-camera compatible format before adding the input
    if #available(iOS 13.0, *) {
      try configureMultiCamFormat(device: secondaryVideoDevice)
    }
    
    let secondaryInput = try AVCaptureDeviceInput(device: secondaryVideoDevice)
    guard session.canAddInput(secondaryInput) else {
      throw CameraError.parameter(.unsupportedInput(inputDescriptor: "secondary-video-input"))
    }
    session.addInputWithNoConnections(secondaryInput)
    secondaryVideoDeviceInput = secondaryInput
    
    // Configure secondary camera outputs
    try configureSecondaryCameraOutputs(session: session, configuration: configuration, videoDevice: secondaryVideoDevice)
  }
  
  private func configurePrimaryCameraOutputs(session: AVCaptureMultiCamSession, configuration: CameraConfiguration, videoDevice: AVCaptureDevice) throws {
    // Find the primary camera device input's video port
    guard let videoDeviceInput = videoDeviceInput,
          let primaryVideoPort = videoDeviceInput.ports(for: .video,
                                                         sourceDeviceType: videoDevice.deviceType,
                                                         sourceDevicePosition: videoDevice.position).first else {
      throw CameraError.parameter(.unsupportedInput(inputDescriptor: "primary-video-port"))
    }
    
    // Photo Output
    if case let .enabled(photo) = configuration.photo {
      VisionLogger.log(level: .info, message: "Adding Primary Photo output...")
      
      let photoOutput = AVCapturePhotoOutput()
      guard session.canAddOutput(photoOutput) else {
        throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "primary-photo-output"))
      }
      session.addOutputWithNoConnections(photoOutput)
      
      // Configure photo output
      if #available(iOS 13.0, *) {
        let qualityPrioritization = AVCapturePhotoOutput.QualityPrioritization(fromQualityBalance: photo.qualityBalance)
        photoOutput.maxPhotoQualityPrioritization = qualityPrioritization
      }
      if photoOutput.isDepthDataDeliverySupported {
        photoOutput.isDepthDataDeliveryEnabled = photo.enableDepthData
      }
      if photoOutput.isPortraitEffectsMatteDeliverySupported {
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = photo.enablePortraitEffectsMatte
      }
      
      // Connect primary camera to photo output
      let photoConnection = AVCaptureConnection(inputPorts: [primaryVideoPort], output: photoOutput)
      guard session.canAddConnection(photoConnection) else {
        throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "primary-photo-connection"))
      }
      session.addConnection(photoConnection)
      
      // Set mirroring on the connection after it's added
      if photoConnection.isVideoMirroringSupported {
        photoConnection.automaticallyAdjustsVideoMirroring = false
        photoConnection.isVideoMirrored = configuration.isMirrored
      }
      
      self.photoOutput = photoOutput
    }
    
    // Video Output
    if case .enabled = configuration.video {
      VisionLogger.log(level: .info, message: "Adding Primary Video Data output...")
      
      let videoOutput = AVCaptureVideoDataOutput()
      guard session.canAddOutput(videoOutput) else {
        throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "primary-video-output"))
      }
      session.addOutputWithNoConnections(videoOutput)
      
      // Configure video output
      videoOutput.setSampleBufferDelegate(self, queue: CameraQueues.videoQueue)
      videoOutput.alwaysDiscardsLateVideoFrames = true
      
      // Set pixel format for PiP mixing - prioritize BGRA for Metal shader compatibility
      VisionLogger.log(level: .info, message: "Available pixel formats for primary video output: \(videoOutput.availableVideoPixelFormatTypes)")
      
      if videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
        VisionLogger.log(level: .info, message: "Setting primary video output to 32BGRA format")
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
      } else if videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_Lossless_32BGRA) {
        VisionLogger.log(level: .info, message: "Setting primary video output to Lossless 32BGRA format")
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_Lossless_32BGRA)]
      } else if videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_Lossy_32BGRA) {
        VisionLogger.log(level: .info, message: "Setting primary video output to Lossy 32BGRA format")
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_Lossy_32BGRA)]
      } else {
        VisionLogger.log(level: .warning, message: "No BGRA format available for primary video output, using default format")
        videoOutput.videoSettings = [:]
      }
      
      // Connect primary camera to video output
      let videoConnection = AVCaptureConnection(inputPorts: [primaryVideoPort], output: videoOutput)
      guard session.canAddConnection(videoConnection) else {
        throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "primary-video-connection"))
      }
      session.addConnection(videoConnection)
      videoConnection.videoOrientation = .portrait
      
      // Set mirroring on the connection after it's added
      if configuration.isMirrored && videoConnection.isVideoMirroringSupported {
        videoConnection.automaticallyAdjustsVideoMirroring = false
        videoConnection.isVideoMirrored = true
      }
      
      self.videoOutput = videoOutput
    }
  }
  
  private func configureSecondaryCameraOutputs(session: AVCaptureMultiCamSession, configuration: CameraConfiguration, videoDevice: AVCaptureDevice) throws {
    // Find the secondary camera device input's video port
    guard let secondaryVideoDeviceInput = secondaryVideoDeviceInput,
          let secondaryVideoPort = secondaryVideoDeviceInput.ports(for: .video,
                                                                    sourceDeviceType: videoDevice.deviceType,
                                                                    sourceDevicePosition: videoDevice.position).first else {
      throw CameraError.parameter(.unsupportedInput(inputDescriptor: "secondary-video-port"))
    }
    
    // Secondary Video Output for PiP
    VisionLogger.log(level: .info, message: "Adding Secondary Video Data output...")
    
    let secondaryVideoOutput = AVCaptureVideoDataOutput()
    guard session.canAddOutput(secondaryVideoOutput) else {
      throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "secondary-video-output"))
    }
    session.addOutputWithNoConnections(secondaryVideoOutput)
    
    // Configure secondary video output
    secondaryVideoOutput.setSampleBufferDelegate(self, queue: CameraQueues.videoQueue)
    secondaryVideoOutput.alwaysDiscardsLateVideoFrames = true
    
    // Set pixel format for PiP mixing - prioritize BGRA for Metal shader compatibility
    VisionLogger.log(level: .info, message: "Available pixel formats for secondary video output: \(secondaryVideoOutput.availableVideoPixelFormatTypes)")
    
    if secondaryVideoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
      VisionLogger.log(level: .info, message: "Setting secondary video output to 32BGRA format")
      secondaryVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    } else if secondaryVideoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_Lossless_32BGRA) {
      VisionLogger.log(level: .info, message: "Setting secondary video output to Lossless 32BGRA format")
      secondaryVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_Lossless_32BGRA)]
    } else if secondaryVideoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_Lossy_32BGRA) {
      VisionLogger.log(level: .info, message: "Setting secondary video output to Lossy 32BGRA format")
      secondaryVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_Lossy_32BGRA)]
    } else {
      VisionLogger.log(level: .warning, message: "No BGRA format available for secondary video output, using default format")
      secondaryVideoOutput.videoSettings = [:]
    }
    
    // Connect secondary camera to video output
    let secondaryVideoConnection = AVCaptureConnection(inputPorts: [secondaryVideoPort], output: secondaryVideoOutput)
    guard session.canAddConnection(secondaryVideoConnection) else {
      throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "secondary-video-connection"))
    }
    session.addConnection(secondaryVideoConnection)
    secondaryVideoConnection.videoOrientation = .portrait
    
    // Mirror front camera if needed
    if videoDevice.position == .front {
      secondaryVideoConnection.automaticallyAdjustsVideoMirroring = false
      secondaryVideoConnection.isVideoMirrored = true
    }
    
    self.secondaryVideoOutput = secondaryVideoOutput
  }
  
  /**
   Get the active capture session (multi-cam or regular)
   */
  var activeCaptureSession: AVCaptureSession {
    return multiCamSession ?? captureSession
  }
  
  /**
   Check if multi-camera mode is active
   */
  var isMultiCamActive: Bool {
    return multiCamSession != nil
  }
  
  /**
   Configure a format that's compatible with AVCaptureMultiCamSession
   */
  @available(iOS 13.0, *)
  private func configureMultiCamFormat(device: AVCaptureDevice) throws {
    VisionLogger.log(level: .info, message: "Configuring multi-camera compatible format for \(device.localizedName)...")
    
    // Find a format that supports multi-camera
    let formats = device.formats.filter { format in
      return format.isMultiCamSupported
    }
    
    guard !formats.isEmpty else {
      throw CameraError.device(.invalid)
    }
    
    // Try to find a reasonable resolution (e.g., 1920x1080 or lower)
    let targetWidth: Int32 = 1920
    let targetHeight: Int32 = 1080
    
    // Sort formats by resolution (prefer smaller resolutions for multi-cam)
    let sortedFormats = formats.sorted { format1, format2 in
      let dims1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
      let dims2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
      
      let area1 = dims1.width * dims1.height
      let area2 = dims2.width * dims2.height
      
      // Prefer formats closer to target resolution
      let targetArea = targetWidth * targetHeight
      let diff1 = abs(area1 - targetArea)
      let diff2 = abs(area2 - targetArea)
      
      return diff1 < diff2
    }
    
    // Select the best format
    guard let selectedFormat = sortedFormats.first else {
      throw CameraError.device(.invalid)
    }
    
    try device.lockForConfiguration()
    defer {
      device.unlockForConfiguration()
    }
    
    device.activeFormat = selectedFormat
    
    // Set a reasonable frame rate (30 fps is usually supported)
    let fps: Float64 = 30
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    
    device.activeVideoMinFrameDuration = frameDuration
    device.activeVideoMaxFrameDuration = frameDuration
    
    let dims = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
    VisionLogger.log(level: .info, message: "Selected multi-cam format: \(dims.width)x\(dims.height)@\(fps)fps")
  }
  
  /**
   Reset device format to a default single-camera compatible format
   */
  private func resetDeviceFormatToDefault(device: AVCaptureDevice) throws {
    VisionLogger.log(level: .info, message: "Resetting device format to default for \(device.localizedName)...")
    
    // Find the first non-multi-cam format (usually the default)
    let singleCamFormats = device.formats.filter { format in
      if #available(iOS 13.0, *) {
        return !format.isMultiCamSupported
      } else {
        return true
      }
    }
    
    // If no non-multi-cam formats, use any format
    let availableFormats = singleCamFormats.isEmpty ? device.formats : singleCamFormats
    
    guard let defaultFormat = availableFormats.first else {
      throw CameraError.device(.invalid)
    }
    
    try device.lockForConfiguration()
    defer {
      device.unlockForConfiguration()
    }
    
    device.activeFormat = defaultFormat
    
    // Reset frame rate to a conservative default
    let fps: Float64 = 30
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    
    device.activeVideoMinFrameDuration = frameDuration
    device.activeVideoMaxFrameDuration = frameDuration
    
    let dims = CMVideoFormatDescriptionGetDimensions(defaultFormat.formatDescription)
    VisionLogger.log(level: .info, message: "Reset to single-cam format: \(dims.width)x\(dims.height)@\(fps)fps")
  }
}