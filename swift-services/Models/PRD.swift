import Foundation

// MARK: - PRD Root

struct PRD: Codable {
    var project: String
    var branchName: String
    var description: String
    var orchestration: Orchestration
    var phases: [Phase]

    // Legacy format support (flat userStories, no phases)
    var userStories: [UserStory]?

    var isLegacy: Bool { phases.isEmpty && userStories != nil }
    var allPhasesComplete: Bool { phases.allSatisfy { $0.status == .complete } }

    var currentPhase: Phase? {
        let idx = orchestration.currentPhaseIndex
        guard idx < phases.count else { return nil }
        return phases[idx]
    }
}

// MARK: - Orchestration

struct Orchestration: Codable {
    var currentPhaseIndex: Int
    var status: OrchestratorStatus
    var dualPrdComplete: Bool
    var maxPlanRetries: Int

    enum CodingKeys: String, CodingKey {
        case currentPhaseIndex, status, dualPrdComplete, maxPlanRetries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPhaseIndex = try container.decodeIfPresent(Int.self, forKey: .currentPhaseIndex) ?? 0
        status = try container.decodeIfPresent(OrchestratorStatus.self, forKey: .status) ?? .executing
        dualPrdComplete = try container.decodeIfPresent(Bool.self, forKey: .dualPrdComplete) ?? false
        maxPlanRetries = try container.decodeIfPresent(Int.self, forKey: .maxPlanRetries) ?? 2
    }

    init(currentPhaseIndex: Int = 0, status: OrchestratorStatus = .executing, dualPrdComplete: Bool = false, maxPlanRetries: Int = 2) {
        self.currentPhaseIndex = currentPhaseIndex
        self.status = status
        self.dualPrdComplete = dualPrdComplete
        self.maxPlanRetries = maxPlanRetries
    }
}

enum OrchestratorStatus: String, Codable {
    case executing
    case planning
    case reviewing
    case complete
    case failed
}

// MARK: - Phase

struct Phase: Codable, Identifiable {
    var id: String
    var title: String
    var description: String
    var order: Int
    var status: PhaseStatus
    var reviewApproved: Bool
    var reviewNotes: String
    var planVersion: Int
    var failedStories: [FailedStory]?
    var userStories: [UserStory]

    var allStoriesPass: Bool { userStories.allSatisfy(\.passes) }
    var failingStories: [UserStory] { userStories.filter { !$0.passes } }
    var storyCount: Int { userStories.count }
}

enum PhaseStatus: String, Codable {
    case pending
    case planning
    case inProgress = "in_progress"
    case complete
    case reviewing
}

// MARK: - User Story

struct UserStory: Codable, Identifiable {
    var id: String
    var title: String
    var description: String
    var acceptanceCriteria: [String]
    var priority: Int
    var passes: Bool
    var notes: String
}

// MARK: - Failed Story (from review rejection)

struct FailedStory: Codable {
    var id: String
    var reason: String
    var suggestedFix: String
}

// MARK: - Run Configuration

struct RunConfig {
    var maxIterationsPerPhase: Int = 10
    var throttleDelay: TimeInterval = 30 // seconds between Claude calls
    var skipPlanning: Bool = false
    var enableQualityGate: Bool = true
    var enableDesloppify: Bool = true
    var enableReview: Bool = true
    var enableCodeReview: Bool = false // opt-in
    var maxRateLimitRetries: Int = 3
}

// MARK: - Run Metrics

struct RunMetrics {
    var startTime: Date = .now
    var totalWorkerIterations: Int = 0
    var totalPlanningInstances: Int = 0
    var perPhase: [Int: PhaseMetrics] = [:]

    struct PhaseMetrics {
        var iterations: Int = 0
        var rejections: Int = 0
        var planType: String = "unknown"
    }

    var duration: TimeInterval { Date.now.timeIntervalSince(startTime) }

    func toJSON() -> [String: Any] {
        [
            "completedAt": ISO8601DateFormatter().string(from: .now),
            "durationSeconds": Int(duration),
            "totalWorkerIterations": totalWorkerIterations,
            "totalPlanningInstances": totalPlanningInstances,
            "perPhase": perPhase.mapValues { ["iterations": $0.iterations, "rejections": $0.rejections, "planType": $0.planType] }
        ]
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date = .now
    let source: Source
    let message: String

    enum Source: String {
        case system
        case claude
        case qualityGate
        case review
        case error
    }
}

// MARK: - PRD File I/O

extension PRD {
    static func load(from url: URL) throws -> PRD {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PRD.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Update a specific field and save atomically
    mutating func update(at url: URL, _ mutation: (inout PRD) -> Void) throws {
        mutation(&self)
        try save(to: url)
    }
}
