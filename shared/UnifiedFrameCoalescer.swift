/// Ordered sample accumulator for the continuous streaming send path.
struct UnifiedFrameCoalescer {
    static let sampleRate = 16_000
    /// 8,960 samples at 16 kHz yields a 0.56-second frame.
    static let frameSampleCount = 8_960

    private var pendingSamples = [Float]()

    /// Adds one converted buffer and returns every complete frame it finishes.
    mutating func append(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }

        var frames = [[Float]]()
        var sampleIndex = 0
        while sampleIndex < samples.count {
            let availableFrameSamples = Self.frameSampleCount - pendingSamples.count
            let samplesToAppend = min(availableFrameSamples, samples.count - sampleIndex)
            let endIndex = sampleIndex + samplesToAppend
            pendingSamples.append(contentsOf: samples[sampleIndex..<endIndex])
            sampleIndex = endIndex

            if pendingSamples.count == Self.frameSampleCount {
                frames.append(pendingSamples)
                pendingSamples = []
            }
        }
        return frames
    }

    /// Returns and clears any remainder, or `nil` when no samples are pending.
    mutating func flush() -> [Float]? {
        guard !pendingSamples.isEmpty else { return nil }
        let remainder = pendingSamples
        pendingSamples = []
        return remainder
    }
}
