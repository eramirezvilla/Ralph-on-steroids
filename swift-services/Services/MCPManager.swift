import Foundation

// MARK: - MCP Manager

/// Reads/writes ~/.claude.json to manage MCP server configurations.
/// Source catalog: everything-claude-code/mcp-configs/mcp-servers.json
struct MCPManager {

    // MARK: - Types

    /// The top-level ~/.claude.json structure (partial — only MCP-relevant fields)
    struct ClaudeConfig: Codable {
        var mcpServers: [String: MCPServerConfig]?

        enum CodingKeys: String, CodingKey {
            case mcpServers
        }
    }

    struct MCPServerConfig: Codable {
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var type: String?       // "http" for HTTP-based servers
        var url: String?        // URL for HTTP-based servers
    }

    /// A template for an available MCP server (from bundled catalog)
    struct MCPTemplate: Identifiable {
        var id: String { name }
        var name: String
        var description: String
        var config: MCPServerConfig
        var requiredEnvVars: [String]  // Env vars that must be set
        var priority: Priority

        enum Priority: Int, Comparable {
            case mustHave = 0
            case high = 1
            case medium = 2
            case low = 3
            static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
        }
    }

    // MARK: - Config Path

    private var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    // MARK: - Read/Write Config

    func loadConfig() -> ClaudeConfig {
        guard let data = try? Data(contentsOf: configPath),
              let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else {
            return ClaudeConfig(mcpServers: [:])
        }
        return config
    }

    /// Save MCP config back to ~/.claude.json
    /// IMPORTANT: Preserves all existing fields — only updates mcpServers
    func saveConfig(_ config: ClaudeConfig) throws {
        var existingJSON: [String: Any] = [:]

        // Load existing file to preserve non-MCP fields
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existingJSON = json
        }

        // Encode just the MCP servers
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let mcpData = try? encoder.encode(config.mcpServers),
           let mcpJSON = try? JSONSerialization.jsonObject(with: mcpData) {
            existingJSON["mcpServers"] = mcpJSON
        }

        let outputData = try JSONSerialization.data(withJSONObject: existingJSON, options: [.prettyPrinted, .sortedKeys])
        try outputData.write(to: configPath, options: .atomic)
    }

    // MARK: - Enable/Disable Servers

    func enableServer(_ name: String, config: MCPServerConfig) throws {
        var currentConfig = loadConfig()
        if currentConfig.mcpServers == nil {
            currentConfig.mcpServers = [:]
        }
        currentConfig.mcpServers?[name] = config
        try saveConfig(currentConfig)
    }

    func disableServer(_ name: String) throws {
        var currentConfig = loadConfig()
        currentConfig.mcpServers?.removeValue(forKey: name)
        try saveConfig(currentConfig)
    }

    func isServerEnabled(_ name: String) -> Bool {
        loadConfig().mcpServers?[name] != nil
    }

    func enabledServerNames() -> [String] {
        Array(loadConfig().mcpServers?.keys ?? [:].keys)
    }

    // MARK: - Available Server Catalog

    /// Returns the curated list of MCP servers recommended for the ralph workflow.
    /// Source: everything-claude-code/mcp-configs/mcp-servers.json
    func availableServers() -> [MCPTemplate] {
        [
            MCPTemplate(
                name: "context7",
                description: "Live documentation lookup for libraries (Supabase, Clerk, Next.js, etc.). Essential for using current APIs.",
                config: MCPServerConfig(command: "npx", args: ["-y", "@upstash/context7-mcp@latest"]),
                requiredEnvVars: [],
                priority: .mustHave
            ),
            MCPTemplate(
                name: "playwright",
                description: "Browser automation and testing. Enables visual verification of UI changes.",
                config: MCPServerConfig(command: "npx", args: ["-y", "@anthropic-ai/mcp-server-playwright"]),
                requiredEnvVars: [],
                priority: .high
            ),
            MCPTemplate(
                name: "github",
                description: "GitHub integration for PRs, issues, and repos.",
                config: MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"]),
                requiredEnvVars: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
                priority: .medium
            ),
            MCPTemplate(
                name: "supabase",
                description: "Supabase database operations — run SQL, manage schema.",
                config: MCPServerConfig(command: "npx", args: ["-y", "@supabase/mcp-server-supabase@latest", "--project-ref=YOUR_PROJECT_REF"]),
                requiredEnvVars: ["SUPABASE_ACCESS_TOKEN"],
                priority: .medium
            ),
            MCPTemplate(
                name: "memory",
                description: "Persistent memory across Claude sessions.",
                config: MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-memory"]),
                requiredEnvVars: [],
                priority: .medium
            ),
            MCPTemplate(
                name: "sequential-thinking",
                description: "Chain-of-thought reasoning for complex planning.",
                config: MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-sequential-thinking"]),
                requiredEnvVars: [],
                priority: .low
            ),
            MCPTemplate(
                name: "firecrawl",
                description: "Web scraping and crawling for research.",
                config: MCPServerConfig(command: "npx", args: ["-y", "firecrawl-mcp"]),
                requiredEnvVars: ["FIRECRAWL_API_KEY"],
                priority: .low
            ),
        ]
    }
}
