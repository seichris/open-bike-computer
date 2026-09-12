import Foundation

/// Deliberately separate from the legacy icon matcher, which defaults to
/// straight and matches direction words anywhere (including street names).
enum SpokenManeuverClassifier {
    static func supports(locale: String) -> Bool {
        locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased() == "en"
    }

    static func classify(_ instruction: String, locale: String) -> SpokenManeuverV1 {
        guard supports(locale: locale), instruction.utf8.count <= 2048 else { return .unknown }
        let value = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let rules: [(String, SpokenManeuverV1)] = [
            (#"^(?:make a |make an |take a |turn )?u[- ]?turn\b"#, .uTurn),
            (#"^(?:you have arrived|arrive at|arrive on)\b"#, .arrive),
            (#"^(?:at the roundabout|enter the roundabout|take the roundabout)\b"#, .roundabout),
            (#"^(?:turn |bear |keep )?(?:slight left|slightly left)\b"#, .slightLeft),
            (#"^(?:turn )?sharp left\b"#, .sharpLeft),
            (#"^(?:turn |bear |keep )?(?:slight right|slightly right)\b"#, .slightRight),
            (#"^(?:turn )?sharp right\b"#, .sharpRight),
            (#"^(?:turn|bear|keep) left\b"#, .left),
            (#"^(?:turn|bear|keep) right\b"#, .right),
            (#"^(?:continue straight|go straight|head straight|continue on|continue onto)\b"#, .straight),
            (#"^continue[.!]?$"#, .continueRoute)
        ]
        return rules.first { value.range(of: $0.0, options: .regularExpression) != nil }?.1 ?? .unknown
    }
}
