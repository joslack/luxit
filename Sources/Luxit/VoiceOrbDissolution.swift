import Foundation

/// Persistent particle motion around the cursor. Recorded audio is untouched.
/// The same constants and integration are used by the Metal vertex shader.
struct VoiceOrbDissolution {
    static let innerRadius: Float = 22
    static let outerRadius: Float = 78
    static let radialForce: Float = 920
    static let tangentialForce: Float = 460
    static let spring: Float = 64
    static let damping: Float = 12
    static let attack: Float = 0.065
    static let release: Float = 0.32

    private(set) var offset = SIMD2<Float>.zero
    private(set) var velocity = SIMD2<Float>.zero
    private(set) var amount: Float = 0

    mutating func advance(anchor: SIMD2<Float>, pointer: SIMD2<Float>?, seed: Float, elapsed: Float) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let dt = min(1 / 30, elapsed)
        var influence: Float = 0
        var force = SIMD2<Float>.zero
        if let pointer {
            let delta = anchor - pointer
            let distance = sqrt(delta.x * delta.x + delta.y * delta.y)
            let t = min(1, max(0, (distance - Self.innerRadius) / (Self.outerRadius - Self.innerRadius)))
            influence = 1 - t * t * (3 - 2 * t)
            let direction = distance > 0.001 ? delta / distance : SIMD2(cos(seed), sin(seed))
            let tangent = SIMD2(-direction.y, direction.x)
            force = (direction * Self.radialForce + tangent * (Self.tangentialForce * sin(seed))) * influence
        }
        // Anchor-based influence holds a hole open even after its particles drift.
        // Semi-implicit integration preserves momentum when the cursor leaves.
        velocity += (force - offset * Self.spring - velocity * Self.damping) * dt
        offset += velocity * dt
        amount += (influence - amount) * (1 - exp(-dt / (influence > amount ? Self.attack : Self.release)))
    }
}
