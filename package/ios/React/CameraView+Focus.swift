//
//  CameraView+Focus.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 12.10.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

extension CameraView {
  func focus(point: CGPoint, promise: Promise) {
    withPromise(promise) {
      guard let basePreviewView = self.previewView else {
        throw CameraError.capture(.focusRequiresPreview)
      }
      
      // Focus is only supported on single camera preview
      guard let previewView = basePreviewView as? PreviewView else {
        throw CameraError.capture(.focusNotAvailableInMultiCam)
      }
      
      let normalized = previewView.captureDevicePointConverted(fromLayerPoint: point)
      try cameraSession.focus(point: normalized)
      return nil
    }
  }
}
