import Foundation

/// Where the lid is, expressed as what the effect should look like.
///
/// `delta` is how far the lid has closed from its resting (reference) angle.
/// The three outputs answer different questions and so respond differently:
///   - `progress`  overall fold amount, 0 open → 1 fully folded (eased over the whole span)
///   - `defocus`   optical blur, gentle for the first couple of degrees, substantial by ~12°,
///                 saturating well before the lid is shut
///   - `tilt`      physical rotation from the resting plane, in radians, capped at 85°
struct FoldState: Equatable {
    var progress: Double
    var defocus: Double
    var tilt: Double
    var referenceAngle: Double

    static let clear = FoldState(progress: 0, defocus: 0, tilt: 0, referenceAngle: 110)
    var isClear: Bool { progress == 0 && defocus == 0 && tilt == 0 }

    static func at(angle: Double, reference: Double) -> FoldState {
        guard angle.isFinite, reference.isFinite else { return .clear }
        let ref = min(140, max(5, reference))
        let delta = max(0, ref - angle)
        guard delta > 0 else { return FoldState(progress: 0, defocus: 0, tilt: 0, referenceAngle: ref) }
        // Never compress the whole effect into a couple of sensor degrees when the
        // lid came to rest at a low angle; the OS still owns lid-close sleep.
        let span = max(20, ref - 5)
        let progress = ease(delta / span)
        let onset = 0.22 * ease(delta / 10) * ease(delta / 4)
        let body  = 0.78 * ease((delta - 8) / max(12, 0.45 * span - 8))
        let defocus = min(1, onset + body)
        let tilt = min(85, delta) * .pi / 180
        return FoldState(progress: progress, defocus: defocus, tilt: tilt, referenceAngle: ref)
    }

    static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }
}

/// 48 bytes, mirrored field-for-field by `struct Uniforms` in the Metal source.
/// Do not reorder: `size` must sit at a 16-byte boundary for float2 alignment.
struct DuoUniforms: Equatable {
    var progress: Float = 0
    var tilt: Float = 0
    var defocus: Float = 0
    var coverage: Float = 1
    var size = SIMD2<Float>(1, 1)
    var perspective: Float = 0.7
    var blur: Float = 0.65
    var shadow: Float = 0.65
    var referenceAngle: Float = 110
    var time: Float = 0
    var effect: UInt32 = 0

    init() {}
    init(state: FoldState, size: SIMD2<Float>, perspective: Float, blur: Float, shadow: Float, coverage: Float = 1, time: Float = 0) {
        progress = Float(state.progress); tilt = Float(state.tilt); defocus = Float(state.defocus)
        referenceAngle = Float(state.referenceAngle)
        self.size = size; self.perspective = perspective; self.blur = blur; self.shadow = shadow
        self.coverage = coverage; self.time = time
    }
}
