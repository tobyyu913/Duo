// Offline harness: render a Duo shader on a screenshot at several lid angles.
//
//   duo-render <shader.metal> <input.png> <outdir> [--ref 120] [--deltas 0,2,5,10,15,25,40,60,80]
//              [--perspective 0.7] [--blur 0.65] [--shadow 0.65] [--scale 0.5] [--time 0]
//
// Writes delta_<n>.png per angle plus sheet.png, a labelled contact sheet.
import AppKit
import Metal
import MetalKit

func arg(_ name: String, _ fallback: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return fallback
}
let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
    .enumerated().filter { i, v in
        // drop values that follow a --flag
        let a = CommandLine.arguments.dropFirst()
        guard let idx = a.firstIndex(of: v), idx > a.startIndex else { return true }
        return !a[a.index(before: idx)].hasPrefix("--")
    }.map { $0.element }
guard positional.count >= 3 else {
    FileHandle.standardError.write("usage: duo-render <shader.metal> <input.png> <outdir> [--ref 120] [--deltas 0,5,15,40] [--perspective 0.7] [--blur 0.65] [--shadow 0.65] [--scale 0.5] [--time 0]\n".data(using: .utf8)!)
    exit(2)
}
let shaderPath = positional[0], inputPath = positional[1], outDir = positional[2]
let reference = Double(arg("--ref", "120"))!
let deltas = arg("--deltas", "0,2,5,10,15,25,40,60,80").split(separator: ",").compactMap { Double($0) }
let perspective = Float(arg("--perspective", "0.7"))!, blur = Float(arg("--blur", "0.65"))!, shadow = Float(arg("--shadow", "0.65"))!
let scale = Double(arg("--scale", "0.5"))!, time = Float(arg("--time", "0"))!

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("no Metal device") }

// Compile the shader from source exactly as the app will.
let source = try String(contentsOfFile: shaderPath, encoding: .utf8)
let library: MTLLibrary
do { library = try device.makeLibrary(source: source, options: nil) }
catch { FileHandle.standardError.write("SHADER COMPILE FAILED:\n\(error)\n".data(using: .utf8)!); exit(1) }
guard let vfn = library.makeFunction(name: "duoVertex"), let ffn = library.makeFunction(name: "duoFragment") else {
    FileHandle.standardError.write("shader must define duoVertex and duoFragment\n".data(using: .utf8)!); exit(1)
}
let desc = MTLRenderPipelineDescriptor()
desc.vertexFunction = vfn; desc.fragmentFunction = ffn
desc.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: desc)

// Load the screenshot as a BGRA texture with a full mip chain (matches the app's renderer).
let loader = MTKTextureLoader(device: device)
let desktop = try loader.newTexture(URL: URL(fileURLWithPath: inputPath),
    options: [.SRGB: false, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue])
let W = Int(Double(desktop.width) * scale), H = Int(Double(desktop.height) * scale)
let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
outDesc.usage = [.renderTarget, .shaderRead]; outDesc.storageMode = .shared
let target = device.makeTexture(descriptor: outDesc)!

func render(_ u: DuoUniforms) -> NSImage {
    var uniforms = u
    let cmd = queue.makeCommandBuffer()!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
    let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(desktop, index: 0)
    enc.setFragmentBytes(&uniforms, length: MemoryLayout<DuoUniforms>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cmd.commit(); cmd.waitUntilCompleted()
    if let e = cmd.error { fatalError("GPU error: \(e)") }
    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    target.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: info.rawValue)!
    return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: W, height: H))
}

func writePNG(_ image: NSImage, _ path: String) {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

var frames: [(String, NSImage)] = []
for delta in deltas {
    let state = FoldState.at(angle: reference - delta, reference: reference)
    let u = DuoUniforms(state: state, size: SIMD2(Float(W), Float(H)), perspective: perspective, blur: blur, shadow: shadow, time: time)
    let img = render(u)
    let name = String(format: "delta_%02d", Int(delta))
    writePNG(img, "\(outDir)/\(name).png")
    let label = String(format: "Δ%.0f°  p=%.2f  defocus=%.2f  tilt=%.0f°", delta, state.progress, state.defocus, state.tilt * 180 / .pi)
    frames.append((label, img))
    print("\(name): \(label)")
}

// Contact sheet: 3 columns, labelled.
let cols = 3, rows = (frames.count + cols - 1) / cols
let cellW = 900.0, cellH = cellW * Double(H) / Double(W), labelH = 34.0, pad = 12.0
let sheet = NSImage(size: NSSize(width: Double(cols) * (cellW + pad) + pad, height: Double(rows) * (cellH + labelH + pad) + pad))
sheet.lockFocus()
NSColor(white: 0.12, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white]
for (i, (label, img)) in frames.enumerated() {
    let c = i % cols, r = i / cols
    let x = pad + Double(c) * (cellW + pad)
    let y = sheet.size.height - pad - Double(r + 1) * (cellH + labelH + pad) + pad
    img.draw(in: NSRect(x: x, y: y + labelH, width: cellW, height: cellH), from: .zero, operation: .copy, fraction: 1)
    (label as NSString).draw(at: NSPoint(x: x + 4, y: y + 6), withAttributes: attrs)
}
sheet.unlockFocus()
writePNG(sheet, "\(outDir)/sheet.png")
print("wrote \(outDir)/sheet.png")
