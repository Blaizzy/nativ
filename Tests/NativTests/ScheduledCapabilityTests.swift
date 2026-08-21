import Foundation
import Testing

@Suite("Scheduled capabilities")
struct ScheduledCapabilityTests {
    @Test("Scheduled task notifications are opt-in")
    func notificationsAreOptIn() throws {
        #expect(Routine().notifyOnFinish == false)

        let json = #"{ "id": "scheduled-1" }"#
        let decoded = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))

        #expect(decoded.notifyOnFinish == false)
    }

    @Test("Capability selections survive persistence")
    func roundTrip() throws {
        let serverID = UUID()
        let skillID = UUID()
        let customToolID = UUID()
        let capabilities: [ScheduledCapability] = [
            .kit("engineering"),
            .mcpServer(serverID),
            .tool(ScheduledTool(provider: .builtIn, name: "get_system_stats")),
            .tool(ScheduledTool(provider: .mcp(serverID), name: "list_issues")),
            .tool(ScheduledTool(provider: .custom(customToolID), name: "custom__triage")),
            .skill(skillID),
        ]
        let scheduled = Routine(
            name: "Issue triage",
            instructions: "Find the most important issue.",
            modelID: "test/model",
            capabilities: capabilities
        )

        let data = try JSONEncoder().encode(scheduled)
        let decoded = try JSONDecoder().decode(Routine.self, from: data)

        #expect(decoded.capabilities == capabilities)
    }

    @Test("An explicit empty capability list takes precedence over legacy data")
    func explicitEmptyCapabilitiesWinOverLegacyKit() throws {
        let json = #"""
        {
          "id": "scheduled-1",
          "capabilities": [],
          "kitID": "engineering"
        }
        """#

        let decoded = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))

        #expect(decoded.capabilities.isEmpty)
    }

    @Test("A custom tool keeps its identity when its function name changes")
    func customToolIdentitySurvivesRename() {
        let id = UUID()
        let original = ScheduledTool(provider: .custom(id), name: "custom__old_name")
        let renamed = ScheduledTool(provider: .custom(id), name: "custom__new_name")

        #expect(original == renamed)
        #expect(Set([original, renamed]).count == 1)
        #expect(
            ScheduledCapability.tool(original).id
                == ScheduledCapability.tool(renamed).id
        )
    }

    @Test("Legacy kit selection migrates to capabilities")
    func legacyKitMigration() throws {
        let json = #"""
        {
          "id": "scheduled-1",
          "name": "Daily review",
          "instructions": "Review my work.",
          "modelID": "test/model",
          "triggerKind": "schedule",
          "schedule": { "weekdays": [], "hour": 9, "minute": 0 },
          "kitID": "engineering",
          "isEnabled": true,
          "notifyOnFinish": true,
          "createdAt": 0
        }
        """#

        let decoded = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))

        #expect(decoded.capabilities == [.kit("engineering")])
        #expect(decoded.notifyOnFinish)
    }

    @Test("New persistence no longer writes the legacy kit field")
    func omitsLegacyKitField() throws {
        let scheduled = Routine(
            name: "Daily review",
            instructions: "Review my work.",
            modelID: "test/model",
            capabilities: [.kit("engineering")]
        )

        let data = try JSONEncoder().encode(scheduled)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["capabilities"] != nil)
        #expect(object["kitID"] == nil)
    }
}
