import Foundation

/// Reproducible, machine-readable record of one fitted chart.
///
/// The report deliberately records source identity and file metadata, not an
/// absolute path, so sharing it does not disclose the user's directory tree.
public struct AnalysisReport: Codable, Sendable, Hashable {
    public struct Source: Codable, Sendable, Hashable {
        public let fileName: String
        public let byteCount: Int64?
        public let modifiedAt: Date?
    }

    public struct Model: Codable, Sendable, Hashable {
        public let engine: String
        public let smoother: String
        public let predictor: String
        public let response: String
        public let responseScale: String
        public let residualDefinition: String
        public let tuningDetail: String?
        public let tuningScore: Double?
        public let tuningReason: String?
        public let tuningNotes: [String]
    }

    public struct Observation: Codable, Sendable, Hashable {
        public let sourceRow: Int
        public let x: Double
        public let observed: Double
        public let fitted: Double?
        public let residual: Double?
    }

    public let schemaVersion: Int
    public let createdAt: Date
    public let source: Source
    public let model: Model
    public let inputObservationCount: Int
    public let retainedObservationCount: Int
    public let droppedObservationCount: Int
    public let assessment: ModelAssessment?
    public let observations: [Observation]

    /// Build a report from the public frontend result. `sourceRow` is
    /// zero-based and addresses the original CSV data rows (excluding header).
    public static func make(
        from loaded: LoadedChart, sourceURL: URL, inputObservationCount: Int,
        sourceRows: [Int]? = nil,
        createdAt: Date = Date()
    ) -> AnalysisReport {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value
        let modifiedAt = attributes?[.modificationDate] as? Date
        let summary = loaded.summary
        let rows = sourceRows ?? loaded.keptIndices
        precondition(rows.count == loaded.model.rawX.count,
                     "sourceRows must align with retained observations")
        let observations = loaded.model.rawX.indices.map { index in
            Observation(
                sourceRow: rows[index],
                x: loaded.model.rawX[index], observed: loaded.model.rawY[index],
                fitted: finiteValue(loaded.model.fittedAtTraining, at: index),
                residual: finiteValue(loaded.model.residuals, at: index)
            )
        }
        return AnalysisReport(
            schemaVersion: 2, createdAt: createdAt,
            source: Source(fileName: sourceURL.lastPathComponent,
                           byteCount: byteCount, modifiedAt: modifiedAt),
            model: Model(
                engine: "Swift-DataLens", smoother: loaded.smootherName,
                predictor: loaded.xName, response: loaded.yName,
                responseScale: loaded.model.responseScale.rawValue,
                residualDefinition: loaded.model.residualKind.rawValue,
                tuningDetail: summary?.detail, tuningScore: summary?.score,
                tuningReason: summary?.reason, tuningNotes: summary?.notes ?? []
            ),
            inputObservationCount: inputObservationCount,
            retainedObservationCount: observations.count,
            droppedObservationCount: max(0, inputObservationCount - observations.count),
            assessment: ModelAssessment.make(from: loaded.model),
            observations: observations
        )
    }

    /// Pretty, stable-key JSON suitable for a provenance sidecar.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Observation-level CSV suitable for auditing in another statistics tool.
    public func observationsCSV() -> String {
        var lines = ["source_row,\(csv(model.predictor)),\(csv(model.response)),fitted,residual"]
        lines += observations.map { observation in
            [String(observation.sourceRow), format(observation.x), format(observation.observed),
             format(observation.fitted), format(observation.residual)].joined(separator: ",")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func finiteValue(_ values: [Double], at index: Int) -> Double? {
        guard values.indices.contains(index), values[index].isFinite else { return nil }
        return values[index]
    }

    private func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(value)
    }

    private func csv(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
