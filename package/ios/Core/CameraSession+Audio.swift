//
//  CameraSession+Audio.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 11.10.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

extension CameraSession {
  /**
   Configures the Audio session and activates it. If the session was active it will shortly be deactivated before configuration.

   The Audio Session will be configured to allow background music, haptics (vibrations) and system sound playback while recording.
   Background audio is allowed to play on speakers or bluetooth speakers.
   */
  final func activateAudioSession() throws {
    VisionLogger.log(level: .info, message: "Activating Audio Session...")

    do {
      let audioSession = AVAudioSession.sharedInstance()

      // Force set category even if it appears to be the same, to ensure clean state
      try audioSession.setCategory(AVAudioSession.Category.playAndRecord,
                                   mode: .videoRecording,
                                   options: [.mixWithOthers,
                                             .allowBluetoothA2DP,
                                             .defaultToSpeaker,
                                             .allowAirPlay])
      VisionLogger.log(level: .info, message: "Audio Session category set to playAndRecord for recording")

      if #available(iOS 14.5, *) {
        // prevents the audio session from being interrupted by a phone call
        try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
      }

      if #available(iOS 13.0, *) {
        // allow system sounds (notifications, calls, music) to play while recording
        try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
      }

      // Ensure audio session is activated
      try audioSession.setActive(true)
      VisionLogger.log(level: .info, message: "Audio Session set to active")

      // Check if audio capture session is already running
      if audioCaptureSession.isRunning {
        VisionLogger.log(level: .info, message: "Audio capture session is already running")
      } else {
        VisionLogger.log(level: .info, message: "Starting audio capture session...")
        audioCaptureSession.startRunning()
        
        // Verify it actually started
        if !audioCaptureSession.isRunning {
          VisionLogger.log(level: .error, message: "Failed to start audio capture session!")
          throw CameraError.session(.audioSessionFailedToActivate)
        }
      }
      
      VisionLogger.log(level: .info, message: "Audio Session activated! (isRunning: \(audioCaptureSession.isRunning))")
    } catch let error as NSError {
      VisionLogger.log(level: .error, message: "Failed to activate audio session! Error \(error.code): \(error.description)")
      switch error.code {
      case 561_017_449:
        throw CameraError.session(.audioInUseByOtherApp)
      default:
        throw CameraError.session(.audioSessionFailedToActivate)
      }
    }
  }

  final func deactivateAudioSession() {
    VisionLogger.log(level: .info, message: "Deactivating Audio Session...")
    
    // Log current state before stopping
    VisionLogger.log(level: .info, message: "Audio capture session state before stop: isRunning=\(audioCaptureSession.isRunning), inputs=\(audioCaptureSession.inputs.count), outputs=\(audioCaptureSession.outputs.count)")

    // Stop the audio capture session
    if audioCaptureSession.isRunning {
      audioCaptureSession.stopRunning()
      VisionLogger.log(level: .info, message: "Audio capture session stopped")
    } else {
      VisionLogger.log(level: .warning, message: "Audio capture session was already stopped")
    }
    
    // Reset AVAudioSession to a clean state for next recording
    do {
      let audioSession = AVAudioSession.sharedInstance()
      
      // Deactivate the audio session first
      try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      VisionLogger.log(level: .info, message: "AVAudioSession deactivated")
      
      // Reset to ambient category to clear any recording-specific configurations
      try audioSession.setCategory(.ambient, mode: .default, options: [])
      VisionLogger.log(level: .info, message: "AVAudioSession category reset to ambient")
    } catch {
      VisionLogger.log(level: .error, message: "Failed to reset AVAudioSession: \(error)")
    }
    
    VisionLogger.log(level: .info, message: "Audio Session completely deactivated!")
  }

  @objc
  func audioSessionInterrupted(notification: Notification) {
    VisionLogger.log(level: .error, message: "Audio Session Interruption Notification!")
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }

    // TODO: Add JS-Event for Audio Session interruptions?
    switch type {
    case .began:
      // Something interrupted our Audio Session, stop recording audio.
      VisionLogger.log(level: .error, message: "The Audio Session was interrupted!")
    case .ended:
      VisionLogger.log(level: .info, message: "The Audio Session interruption has ended.")
      guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      if options.contains(.shouldResume) {
        // Try resuming if possible
        let isRecording = recordingSession != nil
        if isRecording {
          CameraQueues.audioQueue.async {
            VisionLogger.log(level: .info, message: "Resuming interrupted Audio Session...")
            // restart audio session because interruption is over
            try? self.activateAudioSession()
          }
        }
      } else {
        VisionLogger.log(level: .error, message: "Cannot resume interrupted Audio Session!")
      }
    @unknown default:
      ()
    }
  }
}
