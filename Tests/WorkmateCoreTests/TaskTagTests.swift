import Foundation
import Testing
@testable import WorkmateCore

struct TaskTagTests {
    @Test func tagsNormalizeDeduplicateAndSurviveOldAndNewBackups() throws {
        var task = WorkTask(title: "Prepare agenda")
        task.tags = [" #PO-Sync ", "po-sync", " RELease   Planning ", "", "MÖTE"]
        #expect(task.tags == ["po-sync", "release planning", "möte"])
        var workspace = Workspace(); workspace.tasks = [task]
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored.tasks[0].tagNames == task.tagNames)
        _ = try restored.validated()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "tags"); json["tasks"] = tasks
        let legacy = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.tasks[0].tagNames.isEmpty)
        tasks[0]["tags"] = ["PO-SYNC", "po-sync"]; json["tasks"] = tasks
        let imported = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(imported.tasks[0].tags == ["po-sync"])
    }
    @Test func searchFindsTagsAndRespectsArchive() {
        var workspace = Workspace()
        var task = WorkTask(title: "Prepare agenda"); task.tags = ["PO-Sync", "MÖTE"]
        workspace.tasks = [task]
        #expect(workspace.search("#PO-sync").tasks.map(\.id) == [task.id])
        #expect(workspace.search("prepare po sync").tasks.map(\.id) == [task.id])
        #expect(workspace.search("mote").tasks.count == 1)
        workspace.tasks[0].setCompleted(true)
        #expect(workspace.search("po-sync").tasks.isEmpty)
        #expect(workspace.search("po-sync", includeArchived: true).tasks.count == 1)
    }
}
