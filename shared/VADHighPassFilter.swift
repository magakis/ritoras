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
            filtered.append(filter(sample))
        }
        return filtered
    }

    /// Measures the filtered RMS without allocating a second per-frame sample buffer.
    func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var sumSquares: Float = 0
        for sample in samples {
            let filteredSample = filter(sample)
            sumSquares += filteredSample * filteredSample
        }
        return sqrt(sumSquares / Float(samples.count))
    }

    private func filter(_ sample: Float) -> Float {
        guard let previousInput else {
            self.previousInput = sample
            return 0
        }

        let output = alpha * (previousOutput + sample - previousInput)
        self.previousInput = sample
        previousOutput = output
        return output
    }

    func reset() {
        previousInput = nil
        previousOutput = 0
    }
}
