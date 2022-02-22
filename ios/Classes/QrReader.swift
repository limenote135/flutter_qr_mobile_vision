import Foundation
import AVFoundation
import MLKitVision
import MLKitBarcodeScanning
import os.log


extension BarcodeScannerOptions {
  convenience init(formatStrings: [String]) {
    let formats = formatStrings.map { (format) -> BarcodeFormat? in
      switch format  {
      case "ALL_FORMATS":
        return .all
      case "AZTEC":
        return .aztec
      case "CODE_128":
        return .code128
      case "CODE_39":
        return .code39
      case "CODE_93":
        return .code93
      case "CODABAR":
        return .codaBar
      case "DATA_MATRIX":
        return .dataMatrix
      case "EAN_13":
        return .EAN13
      case "EAN_8":
        return .EAN8
      case "ITF":
        return .ITF
      case "PDF417":
        return .PDF417
      case "QR_CODE":
        return .qrCode
      case "UPC_A":
        return .UPCA
      case "UPC_E":
        return .UPCE
      default:
        // ignore any unknown values
        return nil
      }
    }.reduce([]) { (result, format) -> BarcodeFormat in
      guard let format = format else {
        return result
      }
      return result.union(format)
    }
    
    self.init(formats: formats)
  }
}

class OrientationHandler {
  
  var lastKnownOrientation: UIDeviceOrientation!
  
  init() {
    setLastOrientation(UIDevice.current.orientation, defaultOrientation: .portrait)
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    
    NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil, using: orientationDidChange(_:))
  }
  
  func setLastOrientation(_ deviceOrientation: UIDeviceOrientation, defaultOrientation: UIDeviceOrientation?) {
    
    // set last device orientation but only if it is recognized
    switch deviceOrientation {
    case .unknown, .faceUp, .faceDown:
      lastKnownOrientation = defaultOrientation ?? lastKnownOrientation
      break
    default:
      lastKnownOrientation = deviceOrientation
    }
  }
  
  func orientationDidChange(_ notification: Notification) {
    let deviceOrientation = UIDevice.current.orientation
    
    let prevOrientation = lastKnownOrientation
    setLastOrientation(deviceOrientation, defaultOrientation: nil)
    
    if prevOrientation != lastKnownOrientation {
      //TODO: notify of orientation change??? (but mostly why bother...)
    }
  }
  
  deinit {
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
  }
}

protocol QrReaderResponses {
  func surfaceReceived(buffer: CMSampleBuffer)
  func qrReceived(code: String)
}

enum QrReaderError: Error {
  case noCamera
}

class QrReader: NSObject {
  let targetWidth: Int
  let targetHeight: Int
  let textureRegistry: FlutterTextureRegistry
  let isProcessing = Atomic<Bool>(false)
  
  var captureDevice: AVCaptureDevice!
  var captureSession: AVCaptureSession!
  var previewSize: CMVideoDimensions!
  var textureId: Int64!
  var pixelBuffer : CVPixelBuffer?
  let barcodeDetector: BarcodeScanner
  let cameraPosition = AVCaptureDevice.Position.back
  let qrCallback: (_:String) -> Void
  
  init(targetWidth: Int, targetHeight: Int, textureRegistry: FlutterTextureRegistry, options: BarcodeScannerOptions, qrCallback: @escaping (_:String) -> Void) throws {
    self.targetWidth = targetWidth
    self.targetHeight = targetHeight
    self.textureRegistry = textureRegistry
    self.qrCallback = qrCallback
    
    self.barcodeDetector = BarcodeScanner.barcodeScanner()
    
    super.init()
    
    captureSession = AVCaptureSession()
    
    if #available(iOS 10.0, *) {
      captureDevice = AVCaptureDevice.default(AVCaptureDevice.DeviceType.builtInWideAngleCamera, for: AVMediaType.video, position: cameraPosition)
    } else {
      for device in AVCaptureDevice.devices(for: AVMediaType.video) {
        if device.position == cameraPosition {
          captureDevice = device
          break
        }
      }
    }
    
    if captureDevice == nil {
      captureDevice = AVCaptureDevice.default(for: AVMediaType.video)
      
      guard captureDevice != nil else {
        throw QrReaderError.noCamera
      }
    }
    
    let input = try AVCaptureDeviceInput.init(device: captureDevice)
    previewSize = CMVideoFormatDescriptionGetDimensions(captureDevice.activeFormat.formatDescription)
    
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.alwaysDiscardsLateVideoFrames = true
    
    let queue = DispatchQueue.global(qos: DispatchQoS.QoSClass.default)
    output.setSampleBufferDelegate(self, queue: queue)
    
    captureSession.addInput(input)
    captureSession.addOutput(output)
    captureSession.sessionPreset = .hd1920x1080
  }
  
  func start() {
    captureSession.startRunning()
    self.textureId = textureRegistry.register(self)
  }
  
  func stop() {
    captureSession.stopRunning()
    pixelBuffer = nil
    textureRegistry.unregisterTexture(textureId)
    textureId = nil
  }
}

extension QrReader : FlutterTexture {
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        if(pixelBuffer == nil){
            return nil
        }
        return  .passRetained(pixelBuffer!)
    }
}

extension QrReader: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    // runs on dispatch queue
    
    pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
    textureRegistry.textureFrameAvailable(self.textureId)

    let rect: CGRect = CGRect(x: 0, y:0, width: 1920/2, height: 1080)

    let croppedImage = croppedSampleBuffer(sampleBuffer, with: rect)

    guard !isProcessing.swap(true) else {
      return
    }
    
    let image = VisionImage(buffer: croppedImage!)
    image.orientation = imageOrientation(
      deviceOrientation: UIDevice.current.orientation,
      defaultOrientation: .portrait
    )
    
    DispatchQueue.global(qos: DispatchQoS.QoSClass.utility).async {
      self.barcodeDetector.process(image) { features, error in
        self.isProcessing.value = false
        
        guard error == nil else {
          if #available(iOS 10.0, *) {
            os_log("Error decoding barcode %@", error!.localizedDescription)
          } else {
            // Fallback on earlier versions
            NSLog("Error decoding barcode %@", error!.localizedDescription)
          }
          return
        }
        
        guard let features = features, !features.isEmpty else {
          return
        }
                
        for feature in features {
            if let value = feature.rawValue {
                self.qrCallback(value)
            }
        }
      }
    }
  }
    
    

    func imageOrientation(
      deviceOrientation: UIDeviceOrientation,
      defaultOrientation: UIDeviceOrientation
    ) -> UIImage.Orientation {
      switch deviceOrientation {
      case .portrait:
        return cameraPosition == .front ? .leftMirrored : .right
      case .landscapeLeft:
        return cameraPosition == .front ? .downMirrored : .up
      case .portraitUpsideDown:
        return cameraPosition == .front ? .rightMirrored : .left
      case .landscapeRight:
        return cameraPosition == .front ? .upMirrored : .down
      case .faceDown, .faceUp, .unknown:
        return .up
      @unknown default:
        return imageOrientation(deviceOrientation: defaultOrientation, defaultOrientation: .portrait)
        }
    }


  func croppedSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                           with rect: CGRect) -> CMSampleBuffer? {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)

    let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    let bytesPerPixel = bytesPerRow / width
    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return nil }
    let baseAddressStart = baseAddress.assumingMemoryBound(to: UInt8.self)

    var cropX = Int(rect.origin.x)
    let cropY = Int(rect.origin.y)

    // Start pixel in RGB color space can't be odd.
    if cropX % 2 != 0 {
      cropX += 1

    }

    let cropStartOffset = Int(cropY * bytesPerRow + cropX * bytesPerPixel)

    var pixelBuffer: CVPixelBuffer!
    var error: CVReturn

    // Initiates pixelBuffer.
    let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
    let options = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferWidthKey: rect.size.width,
      kCVPixelBufferHeightKey: rect.size.height
    ] as [CFString : Any]

    error = CVPixelBufferCreateWithBytes(kCFAllocatorDefault,
            Int(rect.size.width),
            Int(rect.size.height),
            pixelFormat,
            &baseAddressStart[cropStartOffset],
            Int(bytesPerRow),
            nil,
            nil,
            options as CFDictionary,
            &pixelBuffer)
    if error != kCVReturnSuccess {
      print("Crop CVPixelBufferCreateWithBytes error \(Int(error))")
      return nil
    }


    // Cropping using CIImage.
    var ciImage = CIImage(cvImageBuffer: imageBuffer)
    ciImage = ciImage.cropped(to: rect)
    // CIImage is not in the original point after cropping. So we need to pan.
    ciImage = ciImage.transformed(by: CGAffineTransform(translationX: CGFloat(-cropX), y: CGFloat(-cropY)))

//    let ciContext = CIContext(options: nil)
//    ciContext.render(ciImage, to: pixelBuffer!)
//    gCIContext.render(ciImage, to: pixelBuffer!)

    // Prepares sample timing info.
    var sampleTime = CMSampleTimingInfo()
    sampleTime.duration = CMSampleBufferGetDuration(sampleBuffer)
    sampleTime.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    sampleTime.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)

    var videoInfo: CMVideoFormatDescription!
    error = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescriptionOut: &videoInfo)
    if error != kCVReturnSuccess {
      print("CMVideoFormatDescriptionCreateForImageBuffer error \(Int(error))")
      CVPixelBufferUnlockBaseAddress(imageBuffer, CVPixelBufferLockFlags.readOnly)
      return nil
    }


    // Creates `CMSampleBufferRef`.
    var resultBuffer: CMSampleBuffer?
    error = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: videoInfo,
            sampleTiming: &sampleTime,
            sampleBufferOut: &resultBuffer)
    if error != kCVReturnSuccess {
      print("CMSampleBufferCreateForImageBuffer error \(Int(error))")
    }
    CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
    return resultBuffer
  }

}
