import Foundation

enum AudioMath {
    static func dcCorrectedRMS(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            dcCorrectedRMS(buffer)
        }
    }

    static func dcCorrectedRMS(_ buffer: UnsafeBufferPointer<Float>) -> Float {
        guard !buffer.isEmpty else { return 0 }

        var mean: Float = 0
        for sample in buffer {
            mean += sample
        }
        mean /= Float(buffer.count)

        var sumSquares: Float = 0
        for sample in buffer {
            let centered = sample - mean
            sumSquares += centered * centered
        }
        return sqrt(sumSquares / Float(buffer.count))
    }

    static func dbFromRms(_ rms: Float) -> Float {
        let result = 20 * log10(max(rms, 1e-10))
        return max(result, -100)
    }

    static func rmsFromDb(_ db: Float) -> Float {
        pow(10, db / 20)
    }
}
