import Foundation

/// A `/slots` outcome with its configured-list position and breaker eligibility.
struct KeyboardServicesPinCandidate: Equatable {
    let outcome: ServerSlotsProbeOutcome
    let configuredIndex: Int
    let circuitBreakerOpen: Bool
}

/// Pure selection result for keyboard-services pin publication.
struct KeyboardServicesPinSelectionResult: Equatable {
    let pinnedServer: String?
    let rankedFallbackServers: [String]
    let slotAvailabilityByServer: [String: KeyboardServicesSlotAvailability]
}

/// Ranks capable candidates independently of dictation's `/status` ranking.
enum KeyboardServicesPinSelector {
/// Filters breaker-open servers, then ranks enabled-ready spelling candidates
/// by RTT and configured-list order.
    static func select(
        candidates: [KeyboardServicesPinCandidate]
    ) -> KeyboardServicesPinSelectionResult {
        var availabilityByServer: [String: KeyboardServicesSlotAvailability] = [:]
        for candidate in candidates {
            availabilityByServer[candidate.outcome.serverURL] =
                candidate.outcome.keyboardServicesAvailability
        }

        let rankedCandidates = candidates
            .filter { candidate in
                !candidate.circuitBreakerOpen
                    && candidate.outcome.capability == .keyboardServices
            }
            .sorted { left, right in
                if left.outcome.roundTripTimeMilliseconds
                    != right.outcome.roundTripTimeMilliseconds {
                    return left.outcome.roundTripTimeMilliseconds
                        < right.outcome.roundTripTimeMilliseconds
                }
                return left.configuredIndex < right.configuredIndex
            }
        let rankedFallbackServers = rankedCandidates.map(\.outcome.serverURL)

        return KeyboardServicesPinSelectionResult(
            pinnedServer: rankedFallbackServers.first,
            rankedFallbackServers: rankedFallbackServers,
            slotAvailabilityByServer: availabilityByServer
        )
    }
}
