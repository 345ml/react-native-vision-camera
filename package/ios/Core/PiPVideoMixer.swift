//
//  PiPVideoMixer.swift
//  VisionCamera
//
//  Created by Claude Code on 26.06.25.
//  Copyright © 2025 mrousavy. All rights reserved.
//

import CoreMedia
import CoreVideo
import Metal
import Foundation
import CoreImage

/**
 A video mixer that combines full-screen and picture-in-picture camera feeds using Metal compute shaders
 */
class PiPVideoMixer {
  
  var description = "PiP Video Mixer"
  
  private(set) var isPrepared = false
  
  /// A normalized CGRect representing the position and size of the PiP in relation to the full screen video preview
  var pipFrame = CGRect(x: 0.75, y: 0.1, width: 0.25, height: 0.15)
  
  private(set) var inputFormatDescription: CMFormatDescription?
  
  var outputFormatDescription: CMFormatDescription?
  
  private var outputPixelBufferPool: CVPixelBufferPool?
  
  private let metalDevice = MTLCreateSystemDefaultDevice()
  
  private var textureCache: CVMetalTextureCache?
  
  // Add lock for thread safety during reset operations
  private let resetLock = NSLock()
  
  private lazy var commandQueue: MTLCommandQueue? = {
    guard let metalDevice = metalDevice else {
      return nil
    }
    
    return metalDevice.makeCommandQueue()
  }()
  
  private var computePipelineState: MTLComputePipelineState?
  private var ciContext: CIContext?
  
  // Metal shader source embedded in Swift
  private let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MixerParameters
    {
        float2 pipPosition;
        float2 pipSize;
    };

    constant sampler kBilinearSampler(filter::linear, coord::pixel, address::clamp_to_edge);

    // Compute kernel
    kernel void reporterMixer(texture2d<half, access::read>      fullScreenInput    [[ texture(0) ]],
                              texture2d<half, access::sample>    pipInput           [[ texture(1) ]],
                              texture2d<half, access::write>     outputTexture      [[ texture(2) ]],
                              const device    MixerParameters&   mixerParameters    [[ buffer(0) ]],
                              uint2 gid [[thread_position_in_grid]])
    {
        uint2 pipPosition = uint2(mixerParameters.pipPosition);
        uint2 pipSize = uint2(mixerParameters.pipSize);

        half4 output;

        // Check if the output pixel should be from full screen or PIP
        if ( (gid.x >= pipPosition.x) && (gid.y >= pipPosition.y) &&
             (gid.x < (pipPosition.x + pipSize.x)) && (gid.y < (pipPosition.y + pipSize.y)) )
        {
            // Simplified border and rounded corners
            uint borderWidth = 5;
            float cornerRadius = 15.0;
            
            // Calculate relative position within PiP area
            float2 relPos = float2(gid) - float2(pipPosition);
            
            // Simple border check
            bool isBorder = (relPos.x < borderWidth) || 
                           (relPos.x >= pipSize.x - borderWidth) ||
                           (relPos.y < borderWidth) || 
                           (relPos.y >= pipSize.y - borderWidth);
            
            // Simple corner radius check (approximate)
            bool isCorner = ((relPos.x < cornerRadius && relPos.y < cornerRadius) ||
                           (relPos.x >= pipSize.x - cornerRadius && relPos.y < cornerRadius) ||
                           (relPos.x < cornerRadius && relPos.y >= pipSize.y - cornerRadius) ||
                           (relPos.x >= pipSize.x - cornerRadius && relPos.y >= pipSize.y - cornerRadius));
            
            if (isCorner) {
                // In corner area - simple distance check
                float2 cornerCenter;
                if (relPos.x < cornerRadius && relPos.y < cornerRadius) {
                    cornerCenter = float2(cornerRadius, cornerRadius);
                } else if (relPos.x >= pipSize.x - cornerRadius && relPos.y < cornerRadius) {
                    cornerCenter = float2(pipSize.x - cornerRadius, cornerRadius);
                } else if (relPos.x < cornerRadius && relPos.y >= pipSize.y - cornerRadius) {
                    cornerCenter = float2(cornerRadius, pipSize.y - cornerRadius);
                } else {
                    cornerCenter = float2(pipSize.x - cornerRadius, pipSize.y - cornerRadius);
                }
                
                float distToCenter = distance(relPos, cornerCenter);
                if (distToCenter > cornerRadius) {
                    output = fullScreenInput.read(gid);
                } else if (distToCenter > cornerRadius - borderWidth) {
                    output = half4(1.0, 1.0, 1.0, 1.0);
                } else {
                    // Calculate aspect-ratio preserving sampling coordinates (cover behavior)
                    float2 pipContentSize = float2(pipSize - 2 * borderWidth);
                    float2 inputSize = float2(pipInput.get_width(), pipInput.get_height());
                    
                    // Calculate scale factors for width and height
                    float scaleX = pipContentSize.x / inputSize.x;
                    float scaleY = pipContentSize.y / inputSize.y;
                    
                    // Use the larger scale factor to ensure the image covers the entire area (cover behavior)
                    float scale = max(scaleX, scaleY);
                    
                    // Calculate the scaled input size
                    float2 scaledInputSize = inputSize * scale;
                    
                    // Calculate the offset to center the image
                    float2 offset = (scaledInputSize - pipContentSize) * 0.5;
                    
                    // Calculate the sampling coordinate with aspect ratio preservation
                    float2 adjustedRelPos = (relPos - borderWidth) + offset;
                    float2 pipSamplingCoord = adjustedRelPos * inputSize / scaledInputSize;
                    
                    output = pipInput.sample(kBilinearSampler, pipSamplingCoord + 0.5);
                }
            } else if (isBorder) {
                // Draw white border
                output = half4(1.0, 1.0, 1.0, 1.0);
            } else {
                // Calculate aspect-ratio preserving sampling coordinates (cover behavior)
                float2 pipContentSize = float2(pipSize - 2 * borderWidth);
                float2 inputSize = float2(pipInput.get_width(), pipInput.get_height());
                
                // Calculate scale factors for width and height
                float scaleX = pipContentSize.x / inputSize.x;
                float scaleY = pipContentSize.y / inputSize.y;
                
                // Use the larger scale factor to ensure the image covers the entire area (cover behavior)
                float scale = max(scaleX, scaleY);
                
                // Calculate the scaled input size
                float2 scaledInputSize = inputSize * scale;
                
                // Calculate the offset to center the image
                float2 offset = (scaledInputSize - pipContentSize) * 0.5;
                
                // Calculate the sampling coordinate with aspect ratio preservation
                float2 adjustedRelPos = (relPos - borderWidth) + offset;
                float2 pipSamplingCoord = adjustedRelPos * inputSize / scaledInputSize;
                
                output = pipInput.sample(kBilinearSampler, pipSamplingCoord + 0.5);
            }
        }
        else
        {
            output = fullScreenInput.read(gid);
        }

        outputTexture.write(output, gid);
    }
    """
  
  init() {
    guard let metalDevice = metalDevice else {
      print("PiP Mixer: Failed to create Metal device")
      return
    }
    
    do {
      // Create library from source
      let library = try metalDevice.makeLibrary(source: metalShaderSource, options: nil)
      guard let kernelFunction = library.makeFunction(name: "reporterMixer") else {
        print("PiP Mixer: Failed to create Metal kernel function")
        return
      }
      
      computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction)
      print("PiP Mixer: Metal compute pipeline created successfully")
    } catch {
      print("PiP Mixer: Could not create compute pipeline state: \(error)")
    }
  }
  
  deinit {
    // Ensure complete cleanup when mixer is deallocated
    reset()
    print("PiP Mixer: Deallocated")
  }
  
  func prepare(with videoFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
    reset()
    
    let inputPixelFormat = CMFormatDescriptionGetMediaSubType(videoFormatDescription)
    print("PiP Mixer: Preparing with input format: \(inputPixelFormat)")
    
    (outputPixelBufferPool, _, outputFormatDescription) = allocateOutputBufferPool(with: videoFormatDescription,
                                                                                   outputRetainedBufferCountHint: outputRetainedBufferCountHint)
    if outputPixelBufferPool == nil {
      print("PiP Mixer: Failed to allocate output buffer pool")
      return
    }
    inputFormatDescription = videoFormatDescription
    
    guard let metalDevice = metalDevice else {
      print("PiP Mixer: Metal device unavailable")
      return
    }
    
    // Create Metal texture cache
    var metalTextureCache: CVMetalTextureCache?
    if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
      print("PiP Mixer: Unable to allocate texture cache")
      return
    } else {
      textureCache = metalTextureCache
    }
    
    // Initialize Core Image context with error checking
    ciContext = CIContext(mtlDevice: metalDevice, options: [
      .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
      .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
      .useSoftwareRenderer: false
    ])
    
    if ciContext == nil {
      print("PiP Mixer: Failed to create Core Image context")
      return
    }
    
    isPrepared = true
    print("PiP Mixer: Video Mixer prepared successfully")
  }
  
  func reset() {
    resetLock.lock()
    defer { resetLock.unlock() }
    
    // Mark as not prepared first to prevent new operations
    isPrepared = false
    
    // Reset frame counter
    frameCount = 0
    
    // Flush and clear texture cache before releasing
    if let textureCache = textureCache {
      CVMetalTextureCacheFlush(textureCache, 0)
    }
    textureCache = nil
    
    // Clear pixel buffer pool
    outputPixelBufferPool = nil
    
    // Clear format descriptions
    outputFormatDescription = nil
    inputFormatDescription = nil
    
    // Clear Core Image context to free up resources
    ciContext = nil
    
    // Force memory cleanup
    autoreleasepool {
      // Empty autoreleasepool to force cleanup of any remaining objects
    }
    
    print("PiP Mixer: Resources completely reset")
  }
  
  struct MixerParameters {
    var pipPosition: SIMD2<Float>
    var pipSize: SIMD2<Float>
  }
  
  // Track frame count to handle initial frames specially
  private var frameCount: Int = 0
  
  func mix(fullScreenPixelBuffer: CVPixelBuffer, pipPixelBuffer: CVPixelBuffer, fullScreenPixelBufferIsFrontCamera: Bool = false) -> CVPixelBuffer? {
    guard isPrepared else {
      print("PiP Mixer: Not prepared")
      return nil
    }
    
    guard let outputPixelBufferPool = outputPixelBufferPool else {
      print("PiP Mixer: No output pixel buffer pool")
      return nil
    }
    
    // Check if Core Image context is valid before processing
    guard ciContext != nil else {
      print("PiP Mixer: Core Image context is nil, cannot process frames")
      return nil
    }
    
    var newPixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool, &newPixelBuffer)
    guard let outputPixelBuffer = newPixelBuffer else {
      print("PiP Mixer: Failed to get pixel buffer from pool")
      return nil
    }
    
    // Clear the pixel buffer for the first few frames to prevent green noise
    // This is especially important for the initial frames of the recording
    if frameCount < 3 {
      CVPixelBufferLockBaseAddress(outputPixelBuffer, [])
      let baseAddress = CVPixelBufferGetBaseAddress(outputPixelBuffer)
      let bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer)
      let height = CVPixelBufferGetHeight(outputPixelBuffer)
      if let baseAddress = baseAddress {
        memset(baseAddress, 0, bytesPerRow * height)
      }
      CVPixelBufferUnlockBaseAddress(outputPixelBuffer, [])
    }
    frameCount += 1
    
    // Convert input buffers to BGRA if needed
    let convertedFullScreen = convertToBGRAIfNeeded(pixelBuffer: fullScreenPixelBuffer) ?? fullScreenPixelBuffer
    let convertedPip = convertToBGRAIfNeeded(pixelBuffer: pipPixelBuffer) ?? pipPixelBuffer
    
    guard let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer),
          let fullScreenTexture = makeTextureFromCVPixelBuffer(pixelBuffer: convertedFullScreen),
          let pipTexture = makeTextureFromCVPixelBuffer(pixelBuffer: convertedPip) else {
      return nil
    }
    
    let pipPosition = SIMD2(Float(pipFrame.origin.x) * Float(fullScreenTexture.width), 
                           Float(pipFrame.origin.y) * Float(fullScreenTexture.height))
    
    // Calculate PiP size with fixed aspect ratio (height = width * 1.25)
    let pipWidthPixels = Float(pipFrame.size.width) * Float(fullScreenTexture.width)
    let pipHeightPixels = pipWidthPixels * 1.25  // Fixed aspect ratio
    
    let pipSize = SIMD2(pipWidthPixels, pipHeightPixels)
    var parameters = MixerParameters(pipPosition: pipPosition, pipSize: pipSize)
    
    // Set up command queue, buffer, and encoder with GPU error protection
    guard let commandQueue = commandQueue else {
      print("PiP Mixer: Command queue unavailable")
      return nil
    }
    
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      print("PiP Mixer: Failed to create command buffer")
      return nil
    }
    
    // Add error handler to command buffer
    commandBuffer.addCompletedHandler { [weak self] buffer in
      if buffer.status == .error {
        print("PiP Mixer: Command buffer error: \(String(describing: buffer.error))")
        // Flush texture cache on error to prevent accumulation
        if let textureCache = self?.textureCache {
          CVMetalTextureCacheFlush(textureCache, 0)
        }
      }
    }
    
    guard let commandEncoder = commandBuffer.makeComputeCommandEncoder(),
          let computePipelineState = computePipelineState else {
      print("PiP Mixer: Failed to create Metal command encoder")
      
      // Force flush texture cache and cleanup on failure
      if let textureCache = textureCache {
        CVMetalTextureCacheFlush(textureCache, 0)
      }
      
      return nil
    }
    
    commandEncoder.label = "PiP Video Mixer"
    commandEncoder.setComputePipelineState(computePipelineState)
    commandEncoder.setTexture(fullScreenTexture, index: 0)
    commandEncoder.setTexture(pipTexture, index: 1)
    commandEncoder.setTexture(outputTexture, index: 2)
    withUnsafeMutablePointer(to: &parameters) { parametersRawPointer in
      commandEncoder.setBytes(parametersRawPointer, length: MemoryLayout<MixerParameters>.size, index: 0)
    }
    
    // Set up thread groups
    let width = computePipelineState.threadExecutionWidth
    let height = computePipelineState.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (fullScreenTexture.width + width - 1) / width,
                                      height: (fullScreenTexture.height + height - 1) / height,
                                      depth: 1)
    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    
    commandEncoder.endEncoding()
    commandBuffer.commit()
    
    // Wait for completion synchronously to ensure proper frame ordering
    // This matches Apple's sample implementation pattern
    commandBuffer.waitUntilCompleted()
    
    // Check command buffer status after completion
    if commandBuffer.status != .completed {
      print("PiP Mixer: Command buffer did not complete successfully: \(commandBuffer.status.rawValue)")
      if let error = commandBuffer.error {
        print("PiP Mixer: Command buffer error: \(error)")
      }
      // Still flush cache to prevent accumulation
      if let textureCache = textureCache {
        CVMetalTextureCacheFlush(textureCache, 0)
      }
      return nil
    }
    
    // Flush texture cache after each frame to prevent accumulation
    if let textureCache = textureCache {
      CVMetalTextureCacheFlush(textureCache, 0)
    }
    
    return outputPixelBuffer
  }
  
  private func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
    guard let textureCache = textureCache else {
      print("PiP Mixer: No texture cache available")
      return nil
    }
    
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    
    // Create a Metal texture from the image buffer
    var cvTextureOut: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, 
      textureCache, 
      pixelBuffer, 
      nil, 
      .bgra8Unorm, 
      width, 
      height, 
      0, 
      &cvTextureOut
    )
    
    guard status == kCVReturnSuccess, 
          let cvTexture = cvTextureOut, 
          let texture = CVMetalTextureGetTexture(cvTexture) else {
      print("PiP Mixer: Failed to create Metal texture from pixel buffer. Status: \(status)")
      CVMetalTextureCacheFlush(textureCache, 0)
      return nil
    }
    
    return texture
  }
  
  private func convertToBGRAIfNeeded(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    
    // Already BGRA, no conversion needed
    if pixelFormat == kCVPixelFormatType_32BGRA ||
       pixelFormat == kCVPixelFormatType_Lossless_32BGRA ||
       pixelFormat == kCVPixelFormatType_Lossy_32BGRA {
      return nil
    }
    
    // Convert YUV to BGRA using Core Image
    guard let ciContext = ciContext else {
      print("PiP Mixer: No CI context available - attempting to recreate")
      // Try to recreate CI context if it's nil
      if let metalDevice = metalDevice {
        self.ciContext = CIContext(mtlDevice: metalDevice, options: [
          .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
          .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
          .useSoftwareRenderer: false
        ])
        guard let recreatedContext = self.ciContext else {
          print("PiP Mixer: Failed to recreate CI context")
          return nil
        }
        print("PiP Mixer: Successfully recreated CI context")
        // Use the recreated context
        return convertToBGRAWithContext(pixelBuffer: pixelBuffer, context: recreatedContext)
      } else {
        print("PiP Mixer: Metal device unavailable for CI context recreation")
        return nil
      }
    }
    
    return convertToBGRAWithContext(pixelBuffer: pixelBuffer, context: ciContext)
  }
  
  private func convertToBGRAWithContext(pixelBuffer: CVPixelBuffer, context: CIContext) -> CVPixelBuffer? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    
    var convertedPixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &convertedPixelBuffer
    )
    
    guard status == kCVReturnSuccess, let outputBuffer = convertedPixelBuffer else {
      print("PiP Mixer: Failed to create BGRA pixel buffer for conversion")
      return nil
    }
    
    // Use autoreleasepool to ensure immediate cleanup
    autoreleasepool {
      context.render(ciImage, to: outputBuffer)
    }
    
    return outputBuffer
  }
}

// Helper function to allocate output buffer pool (from VisionCamera utilities)
func allocateOutputBufferPool(with inputFormatDescription: CMFormatDescription, 
                              outputRetainedBufferCountHint: Int) -> (CVPixelBufferPool?, [String: Any]?, CMFormatDescription?) {
  let inputMediaSubType = CMFormatDescriptionGetMediaSubType(inputFormatDescription)
  
  // Always output BGRA for Metal processing
  let outputPixelFormat = kCVPixelFormatType_32BGRA
  
  print("PiP Mixer: Input format: \(inputMediaSubType), Output format: \(outputPixelFormat)")
  
  let inputDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
  let pixelBufferAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: UInt(outputPixelFormat),
    kCVPixelBufferWidthKey as String: Int(inputDimensions.width),
    kCVPixelBufferHeightKey as String: Int(inputDimensions.height),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    kCVPixelBufferMetalCompatibilityKey as String: true
  ]
  
  // Note: Pixel aspect ratio is handled automatically by the system
  
  let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
  var cvPixelBufferPool: CVPixelBufferPool?
  let createStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, pixelBufferAttributes as NSDictionary?, &cvPixelBufferPool)
  guard createStatus == kCVReturnSuccess, let pixelBufferPool = cvPixelBufferPool else {
    print("PiP Mixer: Failed to create pixel buffer pool. Status: \(createStatus)")
    return (nil, nil, nil)
  }
  
  preallocateBuffers(pool: pixelBufferPool, allocationThreshold: outputRetainedBufferCountHint)
  
  // Create the output format description
  var pixelBuffer: CVPixelBuffer?
  var outputFormatDescription: CMFormatDescription?
  let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: outputRetainedBufferCountHint] as NSDictionary
  CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pixelBufferPool, auxAttributes, &pixelBuffer)
  if let pixelBuffer = pixelBuffer {
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                  imageBuffer: pixelBuffer,
                                                  formatDescriptionOut: &outputFormatDescription)
  }
  pixelBuffer = nil
  
  return (pixelBufferPool, pixelBufferAttributes, outputFormatDescription)
}

// Helper function to preallocate buffers
private func preallocateBuffers(pool: CVPixelBufferPool, allocationThreshold: Int) {
  var pixelBuffers = [CVPixelBuffer]()
  var error: CVReturn = kCVReturnSuccess
  let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold] as NSDictionary
  var pixelBuffer: CVPixelBuffer?
  while error == kCVReturnSuccess {
    error = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
    if let pixelBuffer = pixelBuffer {
      pixelBuffers.append(pixelBuffer)
    }
    pixelBuffer = nil
  }
  pixelBuffers.removeAll()
}