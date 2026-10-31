import CoreML
import Foundation

/// Streams 16 kHz mono PCM through the bundled Silero v6 CoreML model.
final class SileroVADClassifier {
    static let sampleWindowSize = 576

    private static let modelName = "silero_vad"
    private static let probabilityOutputName = "vad_output"
    private static let hiddenStateInputName = "hidden_state"
    private static let hiddenStateOutputName = "new_hidden_state"
    private static let cellStateInputName = "cell_state"
    private static let cellStateOutputName = "new_cell_state"
    private static let stateShape = [1, 128]

    private let bundle: Bundle
    private var model: MLModel?
    private var hiddenState: MLMultiArray?
    private var cellState: MLMultiArray?
    private var carry: [Float] = []
    private var latestProbability: Double?
    private var unconsumedProbabilities: [Double] = []

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Loads the precompiled `.mlmodelc` on demand and validates its tensor interface.
    func load() throws {
        guard model == nil else { return }
        guard let modelURL = bundle.url(
            forResource: Self.modelName,
            withExtension: "mlmodelc"
        ) else {
            throw SileroVADClassifierError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
        try Self.validateInterface(loadedModel.modelDescription)

        let newHiddenState = try Self.makeZeroState()
        let newCellState = try Self.makeZeroState()
        model = loadedModel
        hiddenState = newHiddenState
        cellState = newCellState
    }

    /// Adds audio samples and evaluates each complete 576-sample model window.
    func append(samples: [Float]) throws {
        try load()
        carry.append(contentsOf: samples)

        var consumedSamples = 0
        while carry.count - consumedSamples >= Self.sampleWindowSize {
            let windowEnd = consumedSamples + Self.sampleWindowSize
            try predict(window: carry[consumedSamples..<windowEnd])
            consumedSamples = windowEnd
        }
        if consumedSamples > 0 {
            carry.removeFirst(consumedSamples)
        }
    }

    /// Returns the latest raw model-step probability, if any window has completed.
    func probability() -> Double? {
        latestProbability
    }

    /// Returns each probability produced since the previous drain.
    func takeNewProbabilities() -> [Double] {
        defer { unconsumedProbabilities.removeAll(keepingCapacity: true) }
        return unconsumedProbabilities
    }

    /// Clears pending samples and recurrent state before a new audio route/session.
    func reset() throws {
        carry.removeAll(keepingCapacity: true)
        latestProbability = nil
        unconsumedProbabilities.removeAll(keepingCapacity: true)
        guard model != nil else { return }
        hiddenState = try Self.makeZeroState()
        cellState = try Self.makeZeroState()
    }

    /// Releases the model and its recurrent tensors at the end of a Silero session.
    func unload() {
        model = nil
        hiddenState = nil
        cellState = nil
        carry.removeAll(keepingCapacity: false)
        latestProbability = nil
        unconsumedProbabilities.removeAll(keepingCapacity: false)
    }

    private func predict(window: ArraySlice<Float>) throws {
        guard let model,
              let hiddenState,
              let cellState else {
            throw SileroVADClassifierError.modelNotLoaded
        }
        guard window.count == Self.sampleWindowSize,
              window.allSatisfy(\.isFinite) else {
            throw SileroVADClassifierError.invalidAudioWindow
        }

        do {
            let audioInput = try MLMultiArray(
                shape: [1, NSNumber(value: Self.sampleWindowSize)],
                dataType: .float32
            )
            for (index, sample) in window.enumerated() {
                audioInput[index] = NSNumber(value: sample)
            }

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: audioInput),
                Self.hiddenStateInputName: MLFeatureValue(multiArray: hiddenState),
                Self.cellStateInputName: MLFeatureValue(multiArray: cellState)
            ])
            let output = try model.prediction(from: input)
            guard let probabilityArray = output
                .featureValue(for: Self.probabilityOutputName)?.multiArrayValue,
                  Self.hasShape(probabilityArray, [1, 1, 1]),
                  let newHiddenState = output
                    .featureValue(for: Self.hiddenStateOutputName)?.multiArrayValue,
                  Self.hasShape(newHiddenState, Self.stateShape),
                  let newCellState = output
                    .featureValue(for: Self.cellStateOutputName)?.multiArrayValue,
                  Self.hasShape(newCellState, Self.stateShape) else {
                throw SileroVADClassifierError.invalidPredictionOutput
            }

            let probability = probabilityArray[0].doubleValue
            guard probability.isFinite, (0.0...1.0).contains(probability) else {
                throw SileroVADClassifierError.invalidProbability
            }
            self.hiddenState = newHiddenState
            self.cellState = newCellState
            latestProbability = probability
            unconsumedProbabilities.append(probability)
        } catch let error as SileroVADClassifierError {
            throw error
        } catch {
            throw SileroVADClassifierError.predictionFailed(error)
        }
    }

    private static func validateInterface(_ description: MLModelDescription) throws {
        let inputs = description.inputDescriptionsByName
        let outputs = description.outputDescriptionsByName
        try validateMultiArray(inputs["audio_input"], name: "audio_input", shape: [1, sampleWindowSize])
        try validateMultiArray(inputs[hiddenStateInputName], name: hiddenStateInputName, shape: stateShape)
        try validateMultiArray(inputs[cellStateInputName], name: cellStateInputName, shape: stateShape)
        try validateMultiArray(outputs[probabilityOutputName], name: probabilityOutputName, shape: [1, 1, 1])
        try validateMultiArray(outputs[hiddenStateOutputName], name: hiddenStateOutputName, shape: stateShape)
        try validateMultiArray(outputs[cellStateOutputName], name: cellStateOutputName, shape: stateShape)
    }

    private static func validateMultiArray(
        _ feature: MLFeatureDescription?,
        name: String,
        shape: [Int]
    ) throws {
        guard let feature,
              feature.type == .multiArray,
              let constraint = feature.multiArrayConstraint,
              constraint.dataType == .float32,
              constraint.shape.map(\.intValue) == shape else {
            throw SileroVADClassifierError.incompatibleFeature(name)
        }
    }

    private static func hasShape(_ array: MLMultiArray, _ shape: [Int]) -> Bool {
        array.dataType == .float32 && array.shape.map(\.intValue) == shape
    }

    private static func makeZeroState() throws -> MLMultiArray {
        let state = try MLMultiArray(
            shape: stateShape.map { NSNumber(value: $0) },
            dataType: .float32
        )
        for index in 0..<state.count {
            state[index] = 0
        }
        return state
    }
}

private enum SileroVADClassifierError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case incompatibleFeature(String)
    case invalidAudioWindow
    case invalidPredictionOutput
    case invalidProbability
    case predictionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Bundled silero_vad.mlmodelc was not found."
        case .modelNotLoaded:
            return "Silero VAD model is not loaded."
        case .incompatibleFeature(let name):
            return "Silero VAD model has an incompatible \(name) feature."
        case .invalidAudioWindow:
            return "Silero VAD received an invalid 576-sample window."
        case .invalidPredictionOutput:
            return "Silero VAD model returned an incompatible output."
        case .invalidProbability:
            return "Silero VAD model returned an invalid probability."
        case .predictionFailed(let error):
            return "Silero VAD prediction failed: \(error.localizedDescription)"
        }
    }
}
