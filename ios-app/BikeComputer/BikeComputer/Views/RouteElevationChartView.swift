import SwiftUI

/// Elevation chart drawn from the canonical profile. Unknown stretches stay
/// gaps and estimated stretches (bridges, tunnels, short gaps) are dashed, so
/// the chart never implies more certainty than the data has.
struct RouteElevationChartView: View {
    let profile: RouteElevationProfileV1
    var markerDistanceMeters: Double?
    var height: CGFloat = 84

    private let points: [RouteElevationDeviceProtocolV1.DisplayPoint]

    init(profile: RouteElevationProfileV1, markerDistanceMeters: Double? = nil, height: CGFloat = 84) {
        self.profile = profile
        self.markerDistanceMeters = markerDistanceMeters
        self.height = height
        points = RouteElevationDeviceProtocolV1.displayPoints(profile, maximum: 320)
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Elevation profile")
        .accessibilityValue(RouteElevationText.summary(profile))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let length = profile.geometry.lengthM
        let known = points.compactMap(\.elevationMeters).map(Double.init)
        guard length > 0, let low = known.min(), let high = known.max(), size.width > 0 else { return }
        // A flat route must not turn sensor noise into hills.
        let span = max(high - low, 20)
        let middle = (low + high) / 2
        let bottom = middle - span * 0.58
        let top = middle + span * 0.58
        func x(_ distance: Double) -> CGFloat { CGFloat(min(max(distance / length, 0), 1)) * size.width }
        func y(_ elevation: Double) -> CGFloat { size.height * CGFloat(1 - (elevation - bottom) / (top - bottom)) }

        var runs: [[(point: CGPoint, estimated: Bool)]] = []
        var current: [(point: CGPoint, estimated: Bool)] = []
        for point in points {
            guard let elevation = point.elevationMeters else {
                if !current.isEmpty { runs.append(current) }
                current = []
                continue
            }
            current.append((CGPoint(x: x(Double(point.distanceMeters)), y: y(Double(elevation))),
                            point.flags & (1 << 3) != 0))
        }
        if !current.isEmpty { runs.append(current) }

        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            var area = Path()
            area.move(to: CGPoint(x: first.point.x, y: size.height))
            for item in run { area.addLine(to: item.point) }
            area.addLine(to: CGPoint(x: last.point.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            var solid = Path()
            var dashed = Path()
            for (index, item) in run.enumerated() where index > 0 {
                let previous = run[index - 1]
                var segment = Path()
                segment.move(to: previous.point)
                segment.addLine(to: item.point)
                if item.estimated || previous.estimated { dashed.addPath(segment) } else { solid.addPath(segment) }
            }
            if run.count == 1 {
                solid.addEllipse(in: CGRect(x: first.point.x - 1, y: first.point.y - 1, width: 2, height: 2))
            }
            context.stroke(solid, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            context.stroke(dashed, with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
        }

        if let marker = markerDistanceMeters, marker.isFinite {
            let markerX = x(marker)
            var line = Path()
            line.move(to: CGPoint(x: markerX, y: 0))
            line.addLine(to: CGPoint(x: markerX, y: size.height))
            context.stroke(line, with: .color(.orange.opacity(0.7)), lineWidth: 1.5)
            if let elevation = profile.position(atDistance: marker).elevationMeters {
                let dot = CGRect(x: markerX - 5, y: y(elevation) - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: dot), with: .color(.orange))
                context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

enum RouteElevationText {
    static func meters(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(Int(value.rounded())) m"
    }

    static func grade(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%+.1f%%", value)
    }

    /// Totals cover only known stretches of a partial profile: a lower bound.
    static func total(_ value: Double?, complete: Bool) -> String {
        guard value != nil else { return "--" }
        return (complete ? "" : "≥ ") + meters(value)
    }

    static func summary(_ profile: RouteElevationProfileV1) -> String {
        let statistics = profile.statistics
        var parts = [
            "Total ascent \(total(statistics.totalAscentM, complete: statistics.complete))",
            "descent \(total(statistics.totalDescentM, complete: statistics.complete))",
            "highest \(meters(statistics.maximumElevationM))",
            "lowest \(meters(statistics.minimumElevationM))",
        ]
        if profile.quality.status == RouteElevationContractV1.qualityPartial {
            parts.append("partial profile")
        }
        if statistics.includesEstimated { parts.append("includes estimated sections") }
        return parts.joined(separator: ", ")
    }

    static func qualityNotes(_ profile: RouteElevationProfileV1) -> [String] {
        var notes: [String] = []
        if profile.quality.status == RouteElevationContractV1.qualityPartial {
            let percent = Int((profile.quality.coverage * 100).rounded(.down))
            notes.append("Partial profile: elevation data covers \(percent)% of this route.")
        }
        if profile.statistics.includesEstimated {
            notes.append("Dashed sections are estimated, such as bridges, tunnels or short gaps.")
        }
        if profile.hasAmbiguousStructures {
            notes.append("Some bridge or tunnel levels could not be determined and are left unknown.")
        }
        return notes
    }

    static func source(_ profile: RouteElevationProfileV1) -> [String] {
        var lines: [String]
        switch profile.source.kind {
        case "gpx": lines = ["Elevation from the GPX file"]
        default: lines = profile.source.attribution
        }
        lines.append(contentsOf: profile.structureCorrection.attribution)
        return lines
    }

    static func unavailable(_ reason: RouteElevationUnavailableReasonV1) -> (title: String, detail: String?) {
        switch reason {
        case .sourceNotPermitted:
            ("Elevation isn't available for this route source.",
             "Import the route as a GPX file to see its elevation.")
        case .offline:
            ("Elevation needs an internet connection.",
             "A saved route keeps its elevation for offline rides once loaded.")
        case .serviceUnavailable:
            ("Elevation is temporarily unavailable.", nil)
        case .rateLimited:
            ("Elevation lookups are paused for now.", "Try again later.")
        case .noCoverage:
            ("No elevation data covers this route.", nil)
        case .routeNotSupported:
            ("This route is too long or complex for an elevation profile.", nil)
        }
    }

    static func canRetry(_ reason: RouteElevationUnavailableReasonV1) -> Bool {
        switch reason {
        case .offline, .serviceUnavailable: true
        case .sourceNotPermitted, .rateLimited, .noCoverage, .routeNotSupported: false
        }
    }

    static func device(_ status: RouteElevationDeviceStatusV1) -> String? {
        switch status {
        case .notConnected, .connecting, .showingState: nil
        case .unsupportedFirmware: "This Bicino firmware doesn't show route elevation."
        case .sending: "Sending elevation to Bicino…"
        case .delivered: "Elevation sent to Bicino."
        case .failed: "Couldn't send elevation to Bicino."
        }
    }
}

struct RouteElevationStatisticsRow: View {
    let profile: RouteElevationProfileV1

    var body: some View {
        let statistics = profile.statistics
        HStack(spacing: 12) {
            item("arrow.up.right", RouteElevationText.total(statistics.totalAscentM, complete: statistics.complete),
                 "Ascent")
            item("arrow.down.right", RouteElevationText.total(statistics.totalDescentM, complete: statistics.complete),
                 "Descent")
            item("arrow.up.to.line", RouteElevationText.meters(statistics.maximumElevationM), "Highest")
            item("arrow.down.to.line", RouteElevationText.meters(statistics.minimumElevationM), "Lowest")
        }
        .font(.caption)
    }

    private func item(_ icon: String, _ value: String, _ label: String) -> some View {
        Label(value, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityLabel("\(label) \(value)")
    }
}

/// Shared state rendering for previews and navigation.
struct RouteElevationContent: View {
    let state: RouteElevationStateV1
    var markerDistanceMeters: Double?
    var onRetry: (() -> Void)?

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading elevation…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .ready(let profile):
            VStack(alignment: .leading, spacing: 6) {
                RouteElevationChartView(profile: profile, markerDistanceMeters: markerDistanceMeters)
                RouteElevationStatisticsRow(profile: profile)
                ForEach(RouteElevationText.qualityNotes(profile), id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(RouteElevationText.source(profile), id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .unavailable(let reason):
            let text = RouteElevationText.unavailable(reason)
            VStack(alignment: .leading, spacing: 4) {
                Label(text.title, systemImage: "mountain.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = text.detail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onRetry, RouteElevationText.canRetry(reason) {
                    Button("Try Again", action: onRetry).font(.caption.weight(.semibold))
                }
            }
        }
    }
}

/// Saved-route card section. It reads the exact archive by identity when it
/// appears and keeps no coordinates of its own.
struct SavedRouteElevationPreview: View {
    let identity: WatchRouteIdentityV1
    let service: RouteElevationService
    @State private var state: RouteElevationStateV1?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let state {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Elevation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    RouteElevationContent(state: state, onRetry: { attempt += 1 })
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("savedRouteElevation")
            }
        }
        .task(id: "\(identity.routeID.uuidString)|\(identity.revision)|\(identity.contentHash)|\(attempt)") {
            guard let subject = service.subject(for: RouteElevationArchiveBindingV1(
                routeID: identity.routeID, revision: identity.revision, contentHash: identity.contentHash
            )) else {
                state = nil
                return
            }
            if let cached = service.cachedState(for: subject) {
                state = cached
                return
            }
            state = .loading
            let resolved = await service.resolve(subject, retry: attempt > 0)
            guard !Task.isCancelled else { return }
            state = resolved
        }
    }
}

/// Navigation sheet section: the rider's position on the active profile.
struct NavigationElevationSection: View {
    let presentation: RouteElevationNavigationPresentationV1
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let profile = presentation.state.profile {
                HStack(spacing: 18) {
                    value(RouteElevationText.meters(presentation.position?.elevationMeters),
                          label: "elevation", estimated: presentation.position?.elevationEstimated == true)
                    value(RouteElevationText.grade(presentation.position?.gradePercent),
                          label: "grade", estimated: presentation.position?.gradeEstimated == true)
                    value(remaining(profile), label: "to climb", estimated: false)
                }
                if !presentation.onRoute {
                    Text("Off route: elevation resumes when you rejoin the route.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            RouteElevationContent(
                state: presentation.state,
                markerDistanceMeters: presentation.progressMeters,
                onRetry: onRetry
            )
            if let device = RouteElevationText.device(presentation.device) {
                Label(device, systemImage: "bicycle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("navigationElevation")
    }

    private func remaining(_ profile: RouteElevationProfileV1) -> String {
        guard let position = presentation.position else { return "--" }
        return (position.ascentRemainingIsLowerBound ? "≥ " : "") +
            RouteElevationText.meters(position.ascentRemainingMeters)
    }

    private func value(_ text: String, label: String, estimated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(estimated && text != "--" ? "~\(text)" : text)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(text)\(estimated ? ", estimated" : "")")
    }
}
