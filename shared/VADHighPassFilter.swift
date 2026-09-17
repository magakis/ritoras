import Foundation

/// Lightweight one-pole high-pass filter used only for VAD analysis.
/// The captured PCM path never passes through this filter.
final class VADHighPassFilter {
    private let alpha: Float
    private var previousInput: Float?
    private var previousOutput: Float = 0

    init(cutoffHz: Double, sampleRate: Double = 16000.0) {
        let cutoff = max(0.0, cutoffHz)
        let rc = cutoff > 0.0 ? 1.0 / (2.0 * Double.pi * cutoff) : Double.greatestFiniteMagnitude
        let dt = 1.0 / sampleRate
        alpha = Float(rc / (rc + dt))
    }

    func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        var filtered: [Float] = []
        filtered.reserveCapacity(samples.count)
        for sample in samples {
            guard let previousInput else {
                self.previousInput = sample
                filtered.append(0)
                continue
            }

            let output = alpha * (previousOutput + sample - previousInput)
            self.previousInput = sample
            previousOutput = output
            filtered.append(output)
        }
        return filtered
    }

    func reset() {
        previousInput = nil
        previousOutput = 0
    }
}
