//
//  MetalRenderer.swift
//  PixelBufferToNV12
//
//  Created by Mark Lim Pak Mun on 28/04/2024.
//  Copyright © 2024 com.incremental.innovation. All rights reserved.
//

import AppKit
import MetalKit
import Accelerate.vImage

class MetalRenderer: NSObject, MTKViewDelegate
{
    var metalView: MTKView!
    var metalDevice: MTLDevice
    var commandQueue: MTLCommandQueue!

    var renderPipelineState: MTLRenderPipelineState!
    var computePipelineState: MTLComputePipelineState!
    var threadsPerThreadgroup: MTLSize!
    var threadgroupsPerGrid: MTLSize!

    var sourceCGImage: CGImage!

    var srcPixelBuffer: CVPixelBuffer!      // OSType = 32
    var dstPixelBuffer: CVPixelBuffer!      // OSType = '420f'

    var lumaTexture: MTLTexture!            // Y'
    var chromaTexture: MTLTexture!          // CbCr
    var rgbaTexture: MTLTexture!            // Re-constituted RGBA image

    init?(view: MTKView, device: MTLDevice)
    {
        self.metalView = view
        self.metalDevice = device
        self.commandQueue = metalDevice.makeCommandQueue()
        super.init()
        buildResources()
        buildPipelineStates()
        createRGBTexture()
    }

    /*
     Returns an instance of a (non-planar) CVPixelBuffer object with an OSType of 32 (which is 32ARGB).
     */
    func cvPixelBufferFromImage(_ cgImage: CGImage) -> CVPixelBuffer?
    {
        let pixelBufferAttributes = [
            kCGImageSourceShouldCache as String : true,
            kCGImageSourceShouldAllowFloat as String : false,
            //kCVPixelBufferMetalCompatibilityKey as String : true,
            //kCVPixelBufferIOSurfacePropertiesKey as String : [String: Any]() as CFDictionary,
            //kCVPixelBufferCGBitmapContextCompatibilityKey as String : true,
            //kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey as String : true,
            kCVPixelBufferBytesPerRowAlignmentKey as String : 16
        ] as CFDictionary

        var pixBuffer: CVPixelBuffer?
        // If pxbuffer == nil, you will get status code = -6661
        // The pixel format should be kCVPixelFormatType_32BGRA or kCVPixelFormatType_32ARGB.
        var status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         cgImage.width, cgImage.height,
                                         kCVPixelFormatType_32ARGB,     // OSType: 0x00000020
                                         pixelBufferAttributes,
                                         &pixBuffer)
        guard status == kCVReturnSuccess
        else {
            return nil
        }
        status = CVPixelBufferLockBaseAddress(pixBuffer!,
                                              .readOnly)

        let bufferAddress = CVPixelBufferGetBaseAddress(pixBuffer!)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixBuffer!)
        // pixel format of the CGContext must be premultiplied 32ARGB.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        // Create a Quartz 2D context
        guard let context = CGContext(data: bufferAddress,      // destination memory
                                      width: cgImage.width,     // The width, in pixels, of the required bitmap
                                      height: cgImage.height,   // The height, in pixels, of the required bitmap
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: rgbColorSpace,
                                      bitmapInfo: bitmapInfo)
        else {
            return nil
        }
        // No need to flip if running on macOS - confirmed with a Playground project.
        context.draw(cgImage,
                     in: CGRect(x:0, y:0,
                                width: Int(cgImage.width), height: Int(cgImage.height)))

        // The memory of the `baseAddress` will be populated with interleaved ARGB pixels.
        status = CVPixelBufferUnlockBaseAddress(pixBuffer!, .readOnly)

        guard status == kCVReturnSuccess
        else {
            return nil
        }
        return pixBuffer
    }

    // Convert CVPixelBuffer with a pixel format 32ARGB to
    // a CVPixelBuffer with a pixel format 420Yp8_CbCr8
    func configureInfo() -> vImage_ARGBToYpCbCr
    {
        var info = vImage_ARGBToYpCbCr()    // filled with zeroes
        
        // full range 8-bit, clamped to full range
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 0,
            CbCr_bias: 128,
            YpRangeMax: 255,
            CbCrRangeMax: 255,
            YpMax: 255,
            YpMin: 0,
            CbCrMax: 255,
            CbCrMin: 0)
        
        // The contents of `info` object is initialised by the call below. It
        // will be used by the function vImageConvert_ARGB8888To420Yp8_CbCr8
        vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
            &pixelRange,
            &info,
            kvImageARGB8888,
            kvImage420Yp8_CbCr8,
            vImage_Flags(kvImageDoNotTile))
        return info
     }

    /*
     Converts the RGBA pixels of the source CVPixelBuffer object to
     iOS and macOS should support both kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
     and kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
     */
    func convertARGBToNV12(_ src: UnsafeMutableRawPointer?, _ srcStride: Int,
                           _ destYp: UnsafeMutableRawPointer?, _ dstStrideYp: Int,
                           _ destCbCr: UnsafeMutableRawPointer?, _ destStrideCbCr: Int,
                           _ width: vImagePixelCount, _ height: vImagePixelCount,
                           _ info: UnsafePointer<vImage_ARGBToYpCbCr>) -> vImage_Error
    {
        if (width == 0 || height == 0 ||
            src == nil || srcStride == 0 ||
            destYp == nil || dstStrideYp == 0 ||
            destCbCr == nil || destStrideCbCr == 0) {
            return kvImageInvalidParameter
        }

        // Create vImage_Buffers for the call to vImageConvert_ARGB8888To420Yp8_CbCr8
        var srcBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src!),
                                      height: height, width: width,
                                      rowBytes: srcStride)
        // luma buffer
        var ypBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: destYp!),
                                     height: height, width: width,
                                     rowBytes: dstStrideYp)
        // chroma buffer: Half the width and height of luma buffer
        // but the rowBytes values are the same. 1/4 the size of the luma buffer.
        var cbcrBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: destCbCr!),
                                       height: (height + 1) >> 1,
                                       width: (width + 1) >> 1,
                                       rowBytes: destStrideCbCr)
        var permuteMap: [UInt8] = [0,1,2,3]     // No change
        // The reverse call is vImageConvert_420Yp8_CbCr8ToARGB8888
        return vImageConvert_ARGB8888To420Yp8_CbCr8(
            &srcBuffer,         // src ARGB pixel
            &ypBuffer,          // destYp
            &cbcrBuffer,        // destCbCr
            info,               // ptr to vImage_ARGBToYpCbCr object
            &permuteMap,
            vImage_Flags(kvImagePrintDiagnosticsToConsole))
    }

    // The CVPixelBuffer object passed should be backed by an IOSurface.
    // It is also Metal compatible as well as consisting of 2 planes.
    func texturesFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)
    {
        // Check the CVPixelBuffer object is biplanar.
        assert(CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
               "Pixel Buffer should have 2 planes")

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        var baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        var bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: lumaWidth, height: lumaHeight,
            mipmapped: false)
        textureDescr.usage = [.shaderRead]
        textureDescr.storageMode = .managed
        let lumaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        var region = MTLRegionMake2D(0, 0, lumaTexture!.width, lumaTexture!.height)
        lumaTexture!.replace(region: region,
                             mipmapLevel: 0,
                             withBytes: baseAddress!,
                             bytesPerRow: bytesPerRow)  // stride (in bytes) btwn rows of source data

        let cbcrWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        // Re-use the texture descriptor; just change certain properties.
        textureDescr.width = cbcrWidth
        textureDescr.height = cbcrHeight
        textureDescr.pixelFormat = .rg8Unorm
        let chromaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        region = MTLRegionMake2D(0, 0, chromaTexture!.width, chromaTexture!.height)
        chromaTexture!.replace(region: region,
                               mipmapLevel: 0,
                               withBytes: baseAddress!,
                               bytesPerRow: bytesPerRow)  // stride (in bytes) btwn rows of source data

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        return (lumaTexture!, chromaTexture!)
    }
    

    func buildResources()
    {
        guard let url = Bundle.main.urlForImageResource(NSImage.Name("RedFlower.png"))
        else {
            return
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return
        }
        let options = [
            kCGImageSourceShouldCache : true,
            kCGImageSourceShouldAllowFloat : false
        ] as CFDictionary
        
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options)
        else {
            return
        }
        // bitmapInfo = 3 (non-premultiplied RGBA)
        sourceCGImage = image
        srcPixelBuffer = cvPixelBufferFromImage(sourceCGImage)

        let pixelBufferAttributes = [
            kCGImageSourceShouldCache as String : true,
            kCGImageSourceShouldAllowFloat as String : false,
            kCVPixelBufferIOSurfacePropertiesKey as String : [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String : true,
            //kCVPixelBufferPixelFormatTypeKey : NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange as UInt32),
            kCVPixelBufferBytesPerRowAlignmentKey as String : 16
        ] as CFDictionary
        
        // Specifying the pixel format as kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // should create a CVPixelBuffer object backed by an IOSurface with 2 planes.
        // Same width and height as the source CVPixelBuffer object.
        let cvRet = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(srcPixelBuffer!),
            CVPixelBufferGetHeight(srcPixelBuffer!),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, // OSType: '420f'
            pixelBufferAttributes,
            &dstPixelBuffer)
        if cvRet != kCVReturnSuccess {
            // KIV. Put up an NSAlert
            Swift.print("Can't create the biplanar CVPixelBuffer object: \(cvRet)")
            return
        }
        // Notes:
        // OSType: 0x34323066 '420f'
        // Plane 0 width=640 height=640 bytesPerRow=640 (Yp)
        // Plane 1 width=320 height=320 bytesPerRow=640 (CbCr)
        // The 2 planes have the same `bytesPerRow` value even though
        // the size of plane 1 is a quarter than of plane 0
        var info = configureInfo()

        CVPixelBufferLockBaseAddress(srcPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(dstPixelBuffer, .readOnly)
        // Note: the source CVPixelBuffer object is non-planar.
        // The destination CVPixelBuffer object has 2 planes.
        let error = convertARGBToNV12(
            CVPixelBufferGetBaseAddress(srcPixelBuffer),
            CVPixelBufferGetBytesPerRow(srcPixelBuffer),
            CVPixelBufferGetBaseAddressOfPlane(dstPixelBuffer, 0),
            CVPixelBufferGetBytesPerRowOfPlane(dstPixelBuffer, 0),
            CVPixelBufferGetBaseAddressOfPlane(dstPixelBuffer, 1),
            CVPixelBufferGetBytesPerRowOfPlane(dstPixelBuffer, 1),
            UInt(CVPixelBufferGetWidthOfPlane(srcPixelBuffer,  0)),
            UInt(CVPixelBufferGetHeightOfPlane(srcPixelBuffer, 0)),
            &info)
        if error != kCVReturnSuccess {
            // KIV. Put up an NSAlert
            Swift.print("Can't create the biplanar CVPixelBuffer object: \(cvRet)")
            return
        }

        CVPixelBufferUnlockBaseAddress(dstPixelBuffer!, .readOnly)
        CVPixelBufferUnlockBaseAddress(srcPixelBuffer!, .readOnly)

        // Create the luminance and chrominance textures.
        (lumaTexture, chromaTexture) = texturesFromPixelBuffer(dstPixelBuffer!)
    }

    func buildPipelineStates()
    {
        // Load all the shader files with a metal file extension in the project
        guard let library = metalDevice.makeDefaultLibrary()
        else {
            fatalError("Could not load default library from main bundle")
        }

        /// Use a compute shader function to convert YpCbCr colours to RGB colours.
        let kernelFunction = library.makeFunction(name: "YCbCrColorConversion")
        do {
            computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
        }
        catch {
            fatalError("Unable to create compute pipeline state")
        }

        // Instantiate a new instance of MTLTexture to capture the output of kernel function.
        let mtlTextureDesc = MTLTextureDescriptor()
        mtlTextureDesc.textureType = .type2D
        //mtlTextureDesc.pixelFormat = metalView.colorPixelFormat
        mtlTextureDesc.pixelFormat = .bgra8Unorm    // .rgba8Unorm - also works
        mtlTextureDesc.width = sourceCGImage.width
        mtlTextureDesc.height = sourceCGImage.height
        mtlTextureDesc.usage = [.shaderRead, .shaderWrite]
        mtlTextureDesc.storageMode = .managed
        rgbaTexture = metalDevice.makeTexture(descriptor: mtlTextureDesc)

        // To speed up the colour conversion from YpCbCr to RGB, utilise all available threads.
        let w = computePipelineState.threadExecutionWidth
        let h = computePipelineState.maxTotalThreadsPerThreadgroup / w
        threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        threadgroupsPerGrid = MTLSizeMake((mtlTextureDesc.width+threadsPerThreadgroup.width-1) / threadsPerThreadgroup.width,
                                          (mtlTextureDesc.height+threadsPerThreadgroup.height-1) / threadsPerThreadgroup.height,
                                          1)

        /// Create the render pipeline state for the drawable render pass.
        // Set up a descriptor for creating a pipeline state object
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Render Quad Pipeline"
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "quadVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "quadFragmentShader")

        pipelineDescriptor.sampleCount = metalView.sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        // The attributes of the vertices are generated on the fly.
        pipelineDescriptor.vertexDescriptor = nil

        do {
            renderPipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            fatalError("Could not create render pipeline state object: \(error)")
        }
    }

    // Instantiate the RGB texture from the luma and chroma textures.
    func createRGBTexture()
    {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        computeCommandEncoder.label = "Compute Encoder"
        
        computeCommandEncoder.setComputePipelineState(computePipelineState)
        computeCommandEncoder.setTexture(lumaTexture, index: 0)
        computeCommandEncoder.setTexture(chromaTexture, index: 1)
        // The rgbTexture has a storage mode of MTLResourceStorageMode.managed.
        // The rgbTexture will be output by the GPU.
        computeCommandEncoder.setTexture(rgbaTexture, index: 2)
        computeCommandEncoder.dispatchThreadgroups(threadgroupsPerGrid,
                                                    threadsPerThreadgroup: threadsPerThreadgroup)
        computeCommandEncoder.endEncoding()

        // wait
        commandBuffer.addCompletedHandler {
            cb in
            if cb.status == .completed {
                // Managed buffer is updated and synchronized.
                //print("The RGB textures was created successfully.")
            }
            else {
                if cb.status == .error {
                    Swift.print("The textures of each face of the Cube Map could be not created")
                    Swift.print("Command Buffer Status Error")
                }
                else {
                    Swift.print("Command Buffer Status Code: ", commandBuffer.status)
                }
            }
        }
        commandBuffer.commit()
    }

    // Metal Debugger shows the rgbTexture had been rendered correctly.
    func draw(in view: MTKView)
    {
        let commandBuffer = commandQueue.makeCommandBuffer()
        commandBuffer!.label = "Render Drawable"
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else {
            return
        }

        /// Display the texture.
        // Clear the background of the drawable's texture to white
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)

        guard let renderEncoder = commandBuffer!.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }
        renderEncoder.label = "Render Encoder"
        renderEncoder.setRenderPipelineState(renderPipelineState)
        let   textures = [rgbaTexture, lumaTexture, chromaTexture]
        let  viewWidth = Double(view.drawableSize.width)
        let viewHeight = Double(view.drawableSize.height)
        // All 3 rectangles have the same width and height.
        // Only their origins differ.
        // Metal's 2D coord system has its origin at the top left
        //               top-left       bottom-left       bottom-right
        let originsX = [ viewWidth/4,       0,            viewWidth/2]
        let originsY = [    0.0,        viewHeight/2,     viewHeight/2]
        let   widths = [ viewWidth/2,   viewWidth/2,      viewWidth/2]
        let  heights = [viewHeight/2,   viewHeight/2,     viewHeight/2]
        var viewPort = MTLViewport()
        viewPort.znear = -1.0
        viewPort.znear =  1.0
        for i in 0 ..< textures.count {
            viewPort.originX = originsX[i]
            viewPort.originY = originsY[i]
            viewPort.width = widths[i]          // viewWidth/2
            viewPort.height = heights[i]        // viewHeight/2
            renderEncoder.setViewport(viewPort)
            renderEncoder.setFragmentTexture(textures[i],
                                             index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip,
                                         vertexStart: 0,
                                         vertexCount: 4)
        }

        renderEncoder.endEncoding()
        commandBuffer!.present(drawable)
        commandBuffer!.commit()
        commandBuffer!.waitUntilCompleted()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    {

    }

}
