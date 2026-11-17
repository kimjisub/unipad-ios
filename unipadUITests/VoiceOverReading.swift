import Foundation

/// Keeps first-command delivery failures separate from the app's speech checks.
enum VoiceOverReading {
    struct AutomationNotReady: LocalizedError, CustomStringConvertible {
        let underlying: NSError

        var errorDescription: String? { description }

        var description: String {
            "VoiceOver automation not ready (test tool): the first moveForward command after enable() "
                + "could not be delivered; app speech has not been checked. "
                + "\(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)"
        }
    }

    static func firstSpeech(_ moveForward: () throws -> String) throws -> String {
        do {
            return try moveForward()
        } catch {
            let underlying = error as NSError
            guard underlying.domain == "AXVoiceOverAutomationErrorDomain", underlying.code == 3 else {
                throw error
            }
            throw AutomationNotReady(underlying: underlying)
        }
    }
}
