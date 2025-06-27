//
//  MultiCamPreviewView.swift
//  VisionCamera
//
//  Created by Claude Code on 25.06.25.
//  Copyright © 2025 mrousavy. All rights reserved.
//

import AVFoundation
import UIKit

/**
 A PreviewView for multi-camera setups with picture-in-picture functionality
 */
class MultiCamPreviewView: UIView {
  // Preview layers
  private var primaryPreviewLayer: AVCaptureVideoPreviewLayer?
  private var secondaryPreviewLayer: AVCaptureVideoPreviewLayer?
  
  // PiP container
  private var pipContainer: UIView?
  
  // Configuration
  private var pipPosition: CGPoint = CGPoint(x: 0.85, y: 0.15) // Top-right corner (normalized coordinates)
  private var pipSize: CGSize = CGSize(width: 0.25, height: 0.15) // Width: 25%, Height: 15% of parent size
  
  /**
   Initialize with a multi-camera session
   */
  init(frame: CGRect, session: AVCaptureMultiCamSession, primaryPosition: AVCaptureDevice.Position, secondaryPosition: AVCaptureDevice.Position) {
    super.init(frame: frame)
    setupPreviewLayers(session: session, primaryPosition: primaryPosition, secondaryPosition: secondaryPosition)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setupPreviewLayers(session: AVCaptureMultiCamSession, primaryPosition: AVCaptureDevice.Position, secondaryPosition: AVCaptureDevice.Position) {
    // Primary preview layer (full screen)
    primaryPreviewLayer = AVCaptureVideoPreviewLayer()
    primaryPreviewLayer?.setSessionWithNoConnection(session)
    primaryPreviewLayer?.videoGravity = .resizeAspectFill
    
    if let primaryLayer = primaryPreviewLayer {
      layer.addSublayer(primaryLayer)
    }
    
    // Secondary preview layer (PiP)
    secondaryPreviewLayer = AVCaptureVideoPreviewLayer()
    secondaryPreviewLayer?.setSessionWithNoConnection(session)
    secondaryPreviewLayer?.videoGravity = .resizeAspectFill
    
    // Create PiP container
    pipContainer = UIView()
    pipContainer?.layer.cornerRadius = 8
    pipContainer?.layer.masksToBounds = true
    pipContainer?.layer.borderWidth = 2
    pipContainer?.layer.borderColor = UIColor.white.cgColor
    
    if let container = pipContainer, let secondaryLayer = secondaryPreviewLayer {
      addSubview(container)
      container.layer.addSublayer(secondaryLayer)
    }
    
    // Setup connections manually for multi-cam
    setupConnections(session: session, primaryPosition: primaryPosition, secondaryPosition: secondaryPosition)
    
    // Add tap gesture to toggle PiP
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(togglePiP))
    tapGesture.numberOfTapsRequired = 2
    addGestureRecognizer(tapGesture)
  }
  
  private func setupConnections(session: AVCaptureMultiCamSession, primaryPosition: AVCaptureDevice.Position, secondaryPosition: AVCaptureDevice.Position) {
    // Find inputs for each camera position
    var primaryInput: AVCaptureDeviceInput?
    var secondaryInput: AVCaptureDeviceInput?
    
    for input in session.inputs {
      if let deviceInput = input as? AVCaptureDeviceInput {
        if deviceInput.device.position == primaryPosition {
          primaryInput = deviceInput
        } else if deviceInput.device.position == secondaryPosition {
          secondaryInput = deviceInput
        }
      }
    }
    
    // Connect primary camera to primary preview layer
    if let primaryInput = primaryInput,
       let primaryPort = primaryInput.ports(for: .video,
                                            sourceDeviceType: primaryInput.device.deviceType,
                                            sourceDevicePosition: primaryInput.device.position).first,
       let primaryLayer = primaryPreviewLayer {
      
      let primaryConnection = AVCaptureConnection(inputPort: primaryPort, videoPreviewLayer: primaryLayer)
      if session.canAddConnection(primaryConnection) {
        session.addConnection(primaryConnection)
      }
    }
    
    // Connect secondary camera to secondary preview layer  
    if let secondaryInput = secondaryInput,
       let secondaryPort = secondaryInput.ports(for: .video,
                                                sourceDeviceType: secondaryInput.device.deviceType,
                                                sourceDevicePosition: secondaryInput.device.position).first,
       let secondaryLayer = secondaryPreviewLayer {
      
      let secondaryConnection = AVCaptureConnection(inputPort: secondaryPort, videoPreviewLayer: secondaryLayer)
      
      // Mirror front camera if needed
      if secondaryInput.device.position == .front {
        secondaryConnection.automaticallyAdjustsVideoMirroring = false
        secondaryConnection.isVideoMirrored = true
      }
      
      if session.canAddConnection(secondaryConnection) {
        session.addConnection(secondaryConnection)
      }
    }
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    // Layout primary preview layer
    primaryPreviewLayer?.frame = bounds
    
    // Layout PiP container and secondary preview layer
    layoutPiP()
  }
  
  private func layoutPiP() {
    guard let container = pipContainer, let secondaryLayer = secondaryPreviewLayer else { return }
    
    let pipWidth = bounds.width * pipSize.width
    let pipHeight = bounds.height * pipSize.height
    
    let pipX = bounds.width * pipPosition.x - pipWidth / 2
    let pipY = bounds.height * pipPosition.y - pipHeight / 2
    
    container.frame = CGRect(x: pipX, y: pipY, width: pipWidth, height: pipHeight)
    secondaryLayer.frame = container.bounds
  }
  
  @objc private func togglePiP() {
    // Animate PiP position change
    UIView.animate(withDuration: 0.3) {
      // Move PiP to opposite corner
      if self.pipPosition.x > 0.5 {
        // Currently on right side, move to left
        self.pipPosition.x = 0.15
      } else {
        // Currently on left side, move to right  
        self.pipPosition.x = 0.85
      }
      
      if self.pipPosition.y > 0.5 {
        // Currently on bottom, move to top
        self.pipPosition.y = 0.15
      } else {
        // Currently on top, move to bottom
        self.pipPosition.y = 0.85
      }
      
      self.layoutPiP()
    }
  }
  
  /**
   Set the PiP position (normalized coordinates 0.0 to 1.0)
   */
  func setPiPPosition(_ position: CGPoint) {
    pipPosition = CGPoint(x: max(0.0, min(1.0, position.x)), 
                          y: max(0.0, min(1.0, position.y)))
    layoutPiP()
  }
  
  /**
   Set the PiP size (normalized coordinates 0.0 to 1.0)
   */
  func setPiPSize(_ size: CGSize) {
    pipSize = CGSize(width: max(0.1, min(0.5, size.width)),
                     height: max(0.1, min(0.5, size.height)))
    layoutPiP()
  }
}