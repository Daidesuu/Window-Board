import Foundation

final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaces: [SavedWorkspace] = []

    private let defaults: UserDefaults
    private let storageKey = "savedWorkspaces"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func saveWorkspace(name: String, windows: [SavedWindowReference]) -> SavedWorkspace {
        let now = Date()
        let workspace = SavedWorkspace(
            id: UUID(),
            name: name,
            createdAt: now,
            updatedAt: now,
            windows: windows
        )
        workspaces.insert(workspace, at: workspaces.startIndex)
        persist()
        return workspace
    }

    func updateWorkspace(id: SavedWorkspace.ID, name: String? = nil, windows: [SavedWindowReference]? = nil) -> SavedWorkspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        if let name {
            workspaces[index].name = name
        }

        if let windows {
            workspaces[index].windows = windows
        }

        workspaces[index].updatedAt = Date()
        let workspace = workspaces[index]
        persist()
        return workspace
    }

    func deleteWorkspace(id: SavedWorkspace.ID) {
        workspaces.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            workspaces = []
            return
        }

        do {
            workspaces = try JSONDecoder().decode([SavedWorkspace].self, from: data)
        } catch {
            workspaces = []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(workspaces)
            defaults.set(data, forKey: storageKey)
        } catch {
            defaults.removeObject(forKey: storageKey)
        }
    }
}
