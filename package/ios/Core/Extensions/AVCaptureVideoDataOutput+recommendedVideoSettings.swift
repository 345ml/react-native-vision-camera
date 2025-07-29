//
//  AVCaptureVideoDataOutput+recommendedVideoSettings.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 22.11.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

extension AVCaptureVideoDataOutput {
  private func supportsCodec(_ videoCodec: AVVideoCodecType, writingTo fileType: AVFileType) -> Bool {
    let availableCodecs = availableVideoCodecTypesForAssetWriter(writingTo: fileType)
    return availableCodecs.contains(videoCodec)
  }

  /**
   Get the recommended options for an [AVAssetWriter] with the desired [RecordVideoOptions].
   */
  func recommendedVideoSettings(forOptions options: RecordVideoOptions) throws -> [String: Any] {
    let settings: [String: Any]?
    VisionLogger.log(level: .info, message: "Getting recommended video settings for \(options.fileType) file...")
    if let videoCodec = options.codec {
      // User passed a custom codec
      if supportsCodec(videoCodec, writingTo: options.fileType) {
        // The codec is supported, use it
        VisionLogger.log(level: .info, message: "Using codec \(videoCodec)...")
        settings = recommendedVideoSettings(forVideoCodecType: videoCodec, assetWriterOutputFileType: options.fileType)
      } else {
        // The codec is not supported, fall-back to default
        VisionLogger.log(level: .info, message: "Codec \(videoCodec) is not supported, falling back to default...")
        settings = recommendedVideoSettingsForAssetWriter(writingTo: options.fileType)
      }
    } else {
      // User didn't pass a custom codec, just use default
      settings = recommendedVideoSettingsForAssetWriter(writingTo: options.fileType)
    }
    guard var settings else {
      throw CameraError.capture(.createRecorderError(message: "Failed to get video settings!"))
    }

    if let bitRateOverride = options.bitRateOverride {
      // Convert from Mbps -> bps
      let bitsPerSecond = bitRateOverride * 1_000_000
      if settings[AVVideoCompressionPropertiesKey] == nil {
        settings[AVVideoCompressionPropertiesKey] = [:]
      }
      var compressionSettings = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
      let currentBitRate = compressionSettings[AVVideoAverageBitRateKey] as? NSNumber
      VisionLogger.log(level: .info, message: "Setting Video Bit-Rate from \(currentBitRate?.doubleValue.description ?? "nil") bps to \(bitsPerSecond) bps...")

      compressionSettings[AVVideoAverageBitRateKey] = NSNumber(value: bitsPerSecond)
      settings[AVVideoCompressionPropertiesKey] = compressionSettings
    }

    if let bitRateMultiplier = options.bitRateMultiplier {
      // Check if the bit-rate even exists in the settings
      if var compressionSettings = settings[AVVideoCompressionPropertiesKey] as? [String: Any],
         let currentBitRate = compressionSettings[AVVideoAverageBitRateKey] as? NSNumber {
        // Multiply the current value by the given multiplier
        let newBitRate = Int(currentBitRate.doubleValue * bitRateMultiplier)
        VisionLogger.log(level: .info, message: "Setting Video Bit-Rate from \(currentBitRate) bps to \(newBitRate) bps...")

        compressionSettings[AVVideoAverageBitRateKey] = NSNumber(value: newBitRate)
        settings[AVVideoCompressionPropertiesKey] = compressionSettings
      }
    }
    
    // Ensure proper key frame interval for better encoding and streaming
    // This helps prevent green noise artifacts in the initial frames
    if settings[AVVideoCompressionPropertiesKey] == nil {
      settings[AVVideoCompressionPropertiesKey] = [:]
    }
    if var compressionSettings = settings[AVVideoCompressionPropertiesKey] as? [String: Any] {
      // Set key frame interval to 1 second (30 frames at 30fps)
      // This ensures frequent I-frames for better seeking and initial playback
      if compressionSettings[AVVideoMaxKeyFrameIntervalKey] == nil {
        compressionSettings[AVVideoMaxKeyFrameIntervalKey] = NSNumber(value: 30)
        VisionLogger.log(level: .info, message: "Setting key frame interval to 30 frames")
      }
      
      // Also set key frame interval duration for time-based control
      if compressionSettings[AVVideoMaxKeyFrameIntervalDurationKey] == nil {
        compressionSettings[AVVideoMaxKeyFrameIntervalDurationKey] = NSNumber(value: 1.0)
        VisionLogger.log(level: .info, message: "Setting key frame interval duration to 1.0 seconds")
      }
      
      settings[AVVideoCompressionPropertiesKey] = compressionSettings
    }

    return settings
  }
}
