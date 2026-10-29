import Foundation

/// ELV1/EAK1 framing for the authenticated navigation channel. The phone sends
/// a simplified display profile, the canonical statistics, and values it
/// computed at the rider's along-route progress; firmware only stages,
/// validates and draws. See docs/ble-protocol.md "Route elevation profile".
nonisolated enum RouteElevationDeviceProtocolV1 {
    static let frameMagic = Data(RideBLEGeneratedProtocolV1.routeElevationMagic.utf8)
    static let acknowledgementMagic = Data(RideBLEGeneratedProtocolV1.routeElevationAcknowledgementMagic.utf8)
    static let frameVersion: UInt8 = 1
    static let bodyVersion: UInt8 = 1
    static let bodyHeaderBytes = 32
    static let pointBytes = 7
    static let displayMaximumPoints = 160
    static let protocolMaximumPoints = 192
    static let maximumBodyBytes = bodyHeaderBytes + pointBytes * protocolMaximumPoints
    static let maximumChunks = 64
    static let chunkHeaderBytes = 9
    static let acknowledgementBytes = 16
    static let unknownElevation = Int16.min
    static let unknownProgress = UInt32.max

    enum Op: UInt8 {
        case state = 1
        case begin = 2
        case chunk = 3
        case commit = 4
        case progress = 5
    }

    enum State: UInt8 {
        case cleared = 0
        case loading = 1
        case unavailable = 2
        case failed = 3
    }

    enum Reason: UInt8 {
        case unspecified = 0
        case offline = 1
        case sourceNotPermitted = 2
        case serviceUnavailable = 3
        case quotaExhausted = 4
        case noCoverage = 5
        case transferFailed = 6
        case routeTooLong = 7
    }

    enum Result: UInt8 {
        case applied = 0
        case stale = 1
        case malformed = 2
        case crcMismatch = 3
        case incomplete = 4
        case unsupported = 5
    }

    nonisolated struct DisplayPoint: Equatable {
        let sampleIndex: Int
        let distanceMeters: UInt32
        let elevationMeters: Int16?
        let flags: UInt8
    }

    nonisolated struct Acknowledgement: Equatable {
        let op: UInt8
        let result: Result
        let routeToken: UInt32
        let revision: UInt16
        let transferID: UInt16
    }

    static func gradeBand(_ grade: Double?) -> UInt8 {
        guard let grade else { return 0 }
        if grade < -2 { return 1 }
        if grade < 2 { return 2 }
        if grade < 4 { return 3 }
        if grade < 6 { return 4 }
        if grade < 8 { return 5 }
        if grade < 10 { return 6 }
        return 7
    }

    static func whole(_ value: Double) -> Int64 {
        Int64(RouteElevationContractV1.roundHalfAway(value, digits: 0))
    }

    /// Min/max per bucket keeps peaks, valleys and gap boundaries; the totals
    /// shown on the device still come from the canonical profile.
    static func displayPoints(
        _ profile: RouteElevationProfileV1,
        maximum: Int = displayMaximumPoints
    ) -> [DisplayPoint] {
        typealias Contract = RouteElevationContractV1
        let elevations = profile.samples.elevationM
        let count = elevations.count
        var selected: [Int]
        if count <= maximum {
            selected = Array(0..<count)
        } else {
            var buckets = maximum / 2
            var chosen: Set<Int>
            while true {
                chosen = [0, count - 1]
                for bucket in 0..<buckets {
                    let low = bucket * count / buckets
                    let high = (bucket + 1) * count / buckets
                    var position = low
                    while position < high {
                        let known = elevations[position] != nil
                        var end = position
                        while end < high, (elevations[end] != nil) == known { end += 1 }
                        if !known {
                            chosen.insert(position)
                        } else {
                            var minimumIndex = position
                            var maximumIndex = position
                            for index in position..<end {
                                if elevations[index]! < elevations[minimumIndex]! { minimumIndex = index }
                                if elevations[index]! > elevations[maximumIndex]! { maximumIndex = index }
                            }
                            chosen.insert(minimumIndex)
                            chosen.insert(maximumIndex)
                            if position > 0, elevations[position - 1] == nil { chosen.insert(position) }
                            if end < count, elevations[end] == nil { chosen.insert(end - 1) }
                        }
                        position = end
                    }
                }
                if chosen.count <= maximum || buckets == 1 { break }
                buckets = max(1, buckets * 9 / 10)
            }
            selected = chosen.sorted()
        }
        var points: [DisplayPoint] = []
        points.reserveCapacity(selected.count)
        var previous = -1
        for index in selected {
            var aggregated = 0
            for position in (previous + 1)...index { aggregated |= profile.samples.flags[position] }
            previous = index
            var flags = gradeBand(profile.samples.gradePercent[index])
            if aggregated & Contract.flagEstimated != 0 { flags |= 1 << 3 }
            if aggregated & Contract.flagStructureAmbiguous != 0 { flags |= 1 << 4 }
            if aggregated & (Contract.flagBridge | Contract.flagTunnel) != 0 { flags |= 1 << 5 }
            points.append(DisplayPoint(
                sampleIndex: index,
                distanceMeters: UInt32(clamping: whole(profile.samples.distanceM[index])),
                elevationMeters: elevations[index].map { Int16(clamping: whole($0)) },
                flags: flags
            ))
        }
        return points
    }

    static func sourceCode(_ kind: String) -> UInt8 {
        switch kind {
        case "gpx": 1
        case "hosted-terrain": 2
        case "internal-dem": 3
        default: 0
        }
    }

    static func encodeBody(
        _ profile: RouteElevationProfileV1,
        routeToken: UInt32,
        revision: UInt16,
        points: [DisplayPoint]
    ) -> Data? {
        guard routeToken != 0, revision != 0, (2...protocolMaximumPoints).contains(points.count) else {
            return nil
        }
        let statistics = profile.statistics
        var flags: UInt8 = 0
        if statistics.complete { flags |= 1 << 0 }
        if statistics.includesEstimated { flags |= 1 << 1 }
        if profile.quality.status == RouteElevationContractV1.qualityPartial { flags |= 1 << 2 }
        if profile.hasAmbiguousStructures { flags |= 1 << 3 }
        if statistics.totalAscentM != nil { flags |= 1 << 4 }
        if statistics.minimumElevationM != nil { flags |= 1 << 5 }
        let length = profile.geometry.lengthM
        let estimatedPermille = length <= 0 ? 0 : min(1000, whole(profile.quality.estimatedDistanceM / length * 1000))
        var data = Data()
        data.append(bodyVersion)
        data.append(flags)
        data.append(sourceCode(profile.source.kind))
        data.append(UInt8(points.count))
        data.appendLittleEndian(routeToken)
        data.appendLittleEndian(revision)
        data.appendLittleEndian(UInt16(clamping: min(1000, whole(profile.quality.coverage * 1000))))
        data.appendLittleEndian(UInt32(clamping: whole(length)))
        data.appendLittleEndian(UInt32(clamping: whole(statistics.totalAscentM ?? 0)))
        data.appendLittleEndian(UInt32(clamping: whole(statistics.totalDescentM ?? 0)))
        data.appendLittleEndian(Int16(clamping: whole(statistics.minimumElevationM ?? 0)))
        data.appendLittleEndian(Int16(clamping: whole(statistics.maximumElevationM ?? 0)))
        data.appendLittleEndian(UInt16(clamping: estimatedPermille))
        data.appendLittleEndian(UInt16(0))
        for point in points {
            data.appendLittleEndian(point.distanceMeters)
            data.appendLittleEndian(point.elevationMeters ?? unknownElevation)
            data.append(point.flags)
        }
        return data.count <= maximumBodyBytes ? data : nil
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func header(_ op: Op) -> Data {
        var data = frameMagic
        data.append(frameVersion)
        data.append(op.rawValue)
        return data
    }

    static func stateFrame(routeToken: UInt32, revision: UInt16, state: State, reason: Reason) -> Data {
        var data = header(.state)
        data.appendLittleEndian(routeToken)
        data.appendLittleEndian(revision)
        data.append(state.rawValue)
        data.append(reason.rawValue)
        return data
    }

    /// BEGIN, ordered chunks and COMMIT for one body, sized to the write limit.
    static func transferFrames(
        body: Data,
        routeToken: UInt32,
        revision: UInt16,
        transferID: UInt16,
        maximumWriteLength: Int
    ) -> [Data]? {
        let chunkBytes = maximumWriteLength - chunkHeaderBytes
        guard transferID != 0, chunkBytes >= 32, !body.isEmpty, body.count <= maximumBodyBytes else {
            return nil
        }
        let chunks = stride(from: 0, to: body.count, by: chunkBytes).map {
            body.subdata(in: $0..<min(body.count, $0 + chunkBytes))
        }
        guard chunks.count <= maximumChunks else { return nil }
        var begin = header(.begin)
        begin.appendLittleEndian(routeToken)
        begin.appendLittleEndian(revision)
        begin.appendLittleEndian(transferID)
        begin.appendLittleEndian(UInt16(body.count))
        begin.append(UInt8(chunks.count))
        begin.append(0)
        begin.appendLittleEndian(crc32(body))
        var frames = [begin]
        for (index, chunk) in chunks.enumerated() {
            var frame = header(.chunk)
            frame.appendLittleEndian(transferID)
            frame.append(UInt8(index))
            frame.append(chunk)
            frames.append(frame)
        }
        var commit = header(.commit)
        commit.appendLittleEndian(transferID)
        frames.append(commit)
        return frames
    }

    static func progressFrame(
        routeToken: UInt32,
        revision: UInt16,
        sequence: UInt16,
        progressMeters: UInt32,
        position: RouteElevationPositionV1?,
        onRoute: Bool
    ) -> Data {
        var flags: UInt8 = 0
        var elevation: Int16 = 0
        var grade: Int16 = 0
        var remaining: UInt16 = 0
        if onRoute { flags |= 1 << 0 }
        if let position, let value = position.elevationMeters {
            flags |= 1 << 1
            elevation = Int16(clamping: whole(value))
            if position.elevationEstimated { flags |= 1 << 2 }
        }
        if let position, let value = position.gradePercent {
            flags |= 1 << 3
            grade = Int16(clamping: whole(value * 10))
            if position.gradeEstimated { flags |= 1 << 4 }
        }
        if let position, let value = position.ascentRemainingMeters {
            flags |= 1 << 5
            remaining = UInt16(clamping: min(0xFFFF, whole(value)))
            if position.ascentRemainingIsLowerBound { flags |= 1 << 6 }
        }
        var data = header(.progress)
        data.appendLittleEndian(routeToken)
        data.appendLittleEndian(revision)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(progressMeters)
        data.append(flags)
        data.append(0)
        data.appendLittleEndian(elevation)
        data.appendLittleEndian(grade)
        data.appendLittleEndian(remaining)
        return data
    }

    static func decodeAcknowledgement(_ data: Data) -> Acknowledgement? {
        let bytes = [UInt8](data)
        guard bytes.count == acknowledgementBytes, Data(bytes[0..<4]) == acknowledgementMagic,
              bytes[4] == frameVersion, bytes[7] == 0,
              let result = Result(rawValue: bytes[6]) else { return nil }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
                UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        return Acknowledgement(op: bytes[5], result: result, routeToken: u32(8), revision: u16(12),
                               transferID: u16(14))
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
