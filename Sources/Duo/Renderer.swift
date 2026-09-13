import AppKit
import CoreVideo
import MetalKit

/// Smooths `FoldState` targets so 0.01° sensor steps never show, and plays the clear.
///
/// Progress and defocus approach the target exponentially (time constant ≈ 45 ms); tilt
/// follows a critically damped spring (ω ≈ 1/15 ms, integrated analytically so any frame
/// interval is stable). A clear — the target dropping to `.clear` — runs back to zero over
/// 0.5 s with `coverage` fading out during the final 25 % so the real desktop takes over.
struct FoldAnimator {
    static let approachTimeConstant = 0.045
    static let tiltOmega = 1.0 / 0.015
    static let clearDuration = 0.5
    static let coverageFadeStart = 0.75

    private(set) var state: FoldState = .clear
    private(set) var coverage: Double = 0
    private var tiltVelocity = 0.0
    private var clearFrom: FoldState?
    private var clearElapsed = 0.0

    mutating func reset() {
        self = FoldAnimator()
    }

    /// Start already folded and fully covering: the opening reveal plays from here.
    mutating func seed(_ from: FoldState) {
        self = FoldAnimator()
        state = from
        coverage = 1
    }

    /// Advances by `dt` seconds toward `target`. Returns `true` once at rest on the target.
    mutating func step(target: FoldState, dt: Double) -> Bool {
        if target.isClear {
            return stepClear(dt: dt)
        }
        clearFrom = nil
        clearElapsed = 0

        let k = 1 - exp(-dt / Self.approachTimeConstant)
        state.progress += (target.progress - state.progress) * k
        state.defocus += (target.defocus - state.defocus) * k
        state.referenceAngle = target.referenceAngle
        advanceTilt(toward: target.tilt, dt: dt)
        coverage += (1 - coverage) * (1 - exp(-dt / 0.03))

        let settled = abs(target.progress - state.progress) < 1e-4
            && abs(target.defocus - state.defocus) < 1e-4
            && abs(target.tilt - state.tilt) < 1e-5
            && abs(tiltVelocity) < 1e-4
            && coverage > 0.9995
        if settled {
            state = target
            tiltVelocity = 0
            coverage = 1
        }
        return settled
    }

    private mutating func stepClear(dt: Double) -> Bool {
        if state.isClear && clearFrom == nil {
            coverage = 0
            return true
        }
        if clearFrom == nil {
            clearFrom = state
            clearElapsed = 0
            tiltVelocity = 0
        }
        guard let from = clearFrom else { return true }
        clearElapsed += dt
        let t = min(1, clearElapsed / Self.clearDuration)
        let remaining = 1 - FoldState.ease(t)
        state = FoldState(progress: from.progress * remaining,
                          defocus: from.defocus * remaining,
                          tilt: from.tilt * remaining,
                          referenceAngle: from.referenceAngle)
        coverage = t < Self.coverageFadeStart ? 1 : max(0, 1 - (t - Self.coverageFadeStart) / (1 - Self.coverageFadeStart))
        if t >= 1 {
            state = .clear
            coverage = 0
            clearFrom = nil
            return true
        }
        return false
    }

    /// Closed-form critically damped spring: x(t) = (x₀ + (v₀ + ωx₀)t)·e^(−ωt).
    private mutating func advanceTilt(toward target: Double, dt: Double) {
        let omega = Self.tiltOmega
        let d = state.tilt - target
        let v = tiltVelocity
        let b = v + omega * d
        let e = exp(-omega * dt)
        let newD = (d + b * dt) * e
        let newV = (v - omega * b * dt) * e
        state.tilt = target + newD
        tiltVelocity = newV
    }
}

/// Holds Core Video objects until a command buffer completes.
private struct Lifetime: @unchecked Sendable {
    let objects: [Any]
}

extension DuoUniforms {
    /// Size of the shader's `struct Uniforms` (Shaders/CONTRACT.md): 48 bytes, `float2 size` at offset 16.
    static let shaderByteCount = 48
    static let shaderSizeOffset = 16

    /// Debug-only check that the Swift struct still mirrors the Metal one byte for byte.
    /// `setFragmentBytes` copies exactly `stride` bytes, so a reordered or added field would
    /// silently skew every uniform the shader reads rather than fail loudly.
    static func assertLayout() {
        assert(MemoryLayout<DuoUniforms>.stride == shaderByteCount,
               "DuoUniforms stride is \(MemoryLayout<DuoUniforms>.stride), shader expects \(shaderByteCount) bytes — see Shaders/CONTRACT.md")
        assert(MemoryLayout<DuoUniforms>.offset(of: \.size) == shaderSizeOffset,
               "DuoUniforms.size is at offset \(MemoryLayout<DuoUniforms>.offset(of: \.size) ?? -1), shader expects \(shaderSizeOffset)")
    }
}

/// How the user tuned the look; passed to the shader every frame.
struct Appearance: Equatable {
    var perspective: Float = 0.7
    var blur: Float = 0.65
    var shadow: Float = 0.65
}

/// Metal renderer for the overlay: imports captured frames, builds a mip chain, and draws
/// the Duo shader as a full-screen triangle.
@MainActor final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let view: MTKView

    var frames: FrameStore?
    /// Where the lid wants the effect to be right now, sampled once per frame.
    var targetProvider: (TimeInterval) -> FoldState = { _ in .clear }
    var appearance = Appearance()

    /// The first frame of this run is on screen: safe to make the overlay visible.
    var onFirstPresented: (() -> Void)?
    /// Coverage changed; the overlay applies it as window alpha.
    var onCoverage: ((Double) -> Void)?
    /// The clear animation finished and the view paused itself.
    var onClearSettled: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache
    private let inFlight = DispatchSemaphore(value: 3)

    private var desktop: MTLTexture?
    private var importedRevision: UInt64?
    private var renderedRevision: UInt64?
    private var renderedUniforms: DuoUniforms?
    private var lastCoverage: Double?

    private var animator = FoldAnimator()
    private var lastTime: TimeInterval?
    private var effectStart: TimeInterval = 0
    private var run: UInt64 = 0
    private var presentedThisRun = false
    private(set) var isActive = false

    init(device: MTLDevice) throws {
        DuoUniforms.assertLayout()
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw DuoError.message("Metal command queue unavailable.") }
        self.queue = queue

        // Compiled from `duoShaderSource` (Sources/Duo/ShaderSource.swift, generated from
        // Shaders/duo.metal by Tools/gen_shader.sh) at runtime, exactly as Tools/duo-render does.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: duoShaderSource, options: nil)
        } catch {
            throw DuoError.message("Shader failed to compile: \(error.localizedDescription)")
        }
        guard let vertex = library.makeFunction(name: "duoVertex"),
              let fragment = library.makeFunction(name: "duoFragment") else {
            throw DuoError.message("Shader must define duoVertex and duoFragment.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw DuoError.message("Metal texture cache unavailable.")
        }
        textureCache = cache

        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        // Explicitly nil: MTKView defaults its CAMetalLayer colorspace to sRGB (unlike a bare
        // CAMetalLayer), which would make WindowServer colour-match sRGB -> display and visibly
        // oversaturate the desktop. nil = no colour matching, so the display-space pixels SCK
        // captured are presented back unchanged on any display profile (pixel-exact passthrough).
        view.colorspace = nil
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = 120
        view.autoResizeDrawable = true
        super.init()
        view.delegate = self
    }

    // MARK: Control

    /// Start (or restart) following the target from a clear state — or, for an opening reveal,
    /// from an already-folded `seed` so the first frame is the folded desktop at full coverage.
    func begin(at now: TimeInterval = ProcessInfo.processInfo.systemUptime, seed: FoldState? = nil) {
        run &+= 1
        presentedThisRun = false
        if let seed { animator.seed(seed) } else { animator.reset() }
        lastTime = nil
        effectStart = now
        renderedRevision = nil
        renderedUniforms = nil
        lastCoverage = nil
        isActive = true
        view.isPaused = false
    }

    /// Stop drawing immediately and drop the imported frame so its buffers can retire.
    func stop() {
        isActive = false
        view.isPaused = true
        run &+= 1
        animator.reset()
        desktop = nil
        importedRevision = nil
        renderedRevision = nil
        renderedUniforms = nil
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    func setFrameRate(_ fps: Int) {
        let fps = max(1, fps)
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
    }

    var coverage: Double { animator.coverage }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { renderedUniforms = nil }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render() }
    }

    private func render() {
        guard isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let target = targetProvider(now)
        let frame = frames?.latest()

        // Hold the animation at rest until the first captured frame exists, so the reveal
        // starts from the untouched desktop instead of jumping into a half-folded state.
        if frame == nil && !target.isClear {
            lastTime = nil
            return
        }

        let dt = min(1.0 / 20, max(0, now - (lastTime ?? now)))
        lastTime = now
        let settled = animator.step(target: target, dt: dt)
        if animator.coverage != lastCoverage {
            lastCoverage = animator.coverage
            onCoverage?(animator.coverage)
        }
        if settled && target.isClear {
            isActive = false
            view.isPaused = true
            onClearSettled?()
            return
        }
        guard let (pixelBuffer, revision) = frame else { return }

        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        var uniforms = DuoUniforms(state: animator.state,
                                   size: SIMD2(Float(size.width), Float(size.height)),
                                   perspective: appearance.perspective,
                                   blur: appearance.blur,
                                   shadow: appearance.shadow,
                                   coverage: Float(animator.coverage),
                                   time: 0)
        // `time` is excluded from the comparison so a settled overlay does not re-encode.
        let key = uniforms
        if revision == renderedRevision, key == renderedUniforms, presentedThisRun {
            return  // Same frame, same state: leave the last drawable on screen.
        }
        uniforms.time = Float(now - effectStart)

        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }

        let source: CVMetalTexture
        do {
            source = try importFrame(pixelBuffer)
        } catch {
            onFailure?(error.localizedDescription)
            return
        }
        guard let sourceTexture = CVMetalTextureGetTexture(source) else { return }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { return }

        do {
            let mipmapped = try mipChain(for: sourceTexture, revision: revision, command: command)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw DuoError.message("Render encoder unavailable.")
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(mipmapped, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DuoUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } catch {
            importedRevision = nil
            onFailure?(error.localizedDescription)
            return
        }

        let run = self.run
        if !presentedThisRun {
            drawable.addPresentedHandler { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.run == run else { return }
                    self.onFirstPresented?()
                }
            }
        }
        let retained = Lifetime(objects: [pixelBuffer, source])
        command.addCompletedHandler { [weak self, inFlight, retained] buffer in
            // Keep the pixel buffer and its texture alive until the GPU is done with them.
            withExtendedLifetime(retained) {}
            inFlight.signal()
            guard buffer.status == .error else { return }
            let reason = buffer.error?.localizedDescription ?? "Metal rendering failed."
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderedUniforms = nil
                self.onFailure?(reason)
            }
        }
        command.present(drawable)
        command.commit()
        committed = true
        presentedThisRun = true
        renderedRevision = revision
        renderedUniforms = key
    }

    // MARK: Textures

    private func importFrame(_ pixelBuffer: CVPixelBuffer) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &texture)
        guard result == kCVReturnSuccess, let texture else {
            throw DuoError.message("The captured frame could not be imported into Metal.")
        }
        return texture
    }

    /// Blit the new frame into a private mipmapped texture and regenerate its mip chain,
    /// so the shader sees exactly what the offline harness gives it. Reused while the
    /// captured frame is unchanged.
    private func mipChain(for source: MTLTexture, revision: UInt64, command: MTLCommandBuffer) throws -> MTLTexture {
        if desktop?.width != source.width || desktop?.height != source.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: true)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DuoError.message("Could not allocate the desktop texture.")
            }
            desktop = texture
            importedRevision = nil
        }
        guard let desktop else { throw DuoError.message("Desktop texture unavailable.") }
        if importedRevision == revision { return desktop }
        guard let blit = command.makeBlitCommandEncoder() else { throw DuoError.message("Blit encoder unavailable.") }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: desktop, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: desktop)
        blit.endEncoding()
        importedRevision = revision
        return desktop
    }
}
