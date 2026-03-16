import Foundation
import Vision
import AppKit

/// Detected sensitive content region in a screenshot.
struct SensitiveRegion {
    let rect: CGRect
    let type: SensitiveType
    let text: String
}

enum SensitiveType: String {
    case email
    case apiKey
    case ipAddress
    case cardNumber
}

final class OCREngine {

    func recognizeText(in image: CGImage) async -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    func detectSensitiveContent(in observations: [VNRecognizedTextObservation]) -> [SensitiveRegion] {
        var regions: [SensitiveRegion] = []

        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let boundingBox = observation.boundingBox

            // Email pattern
            if text.range(of: #"\S+@\S+\.\S+"#, options: .regularExpression) != nil {
                regions.append(SensitiveRegion(rect: boundingBox, type: .email, text: text))
            }

            // API key patterns: common prefixes (sk-, pk-, api_, key-, token) followed by long strings
            if text.range(of: #"(?:sk|pk|api|key|token|secret|bearer)[_\-]?[A-Za-z0-9_\-]{16,}"#, options: .regularExpression) != nil {
                regions.append(SensitiveRegion(rect: boundingBox, type: .apiKey, text: text))
            }

            // IPv4 address (validates each octet is 0-255)
            if text.range(of: #"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b"#, options: .regularExpression) != nil {
                regions.append(SensitiveRegion(rect: boundingBox, type: .ipAddress, text: text))
            }

            // Credit card-like patterns (16 digits, possibly with spaces/dashes)
            if text.range(of: #"\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b"#, options: .regularExpression) != nil {
                regions.append(SensitiveRegion(rect: boundingBox, type: .cardNumber, text: text))
            }
        }

        return regions
    }
}
