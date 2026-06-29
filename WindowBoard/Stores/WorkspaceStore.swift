import Foundation

final class WorkspaceStore: ObservableObject {
    static let defaultWorkspaceName = "Default"

    @Published private(set) var workspaces: [SavedWorkspace] = []

    private let defaults: UserDefaults
    private let storageKey = "savedWorkspaces"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        ensureDefaultWorkspace()
    }

    var defaultWorkspace: SavedWorkspace? {
        workspaces.first(where: \.isDefault)
    }

    func saveWorkspace(name: String, windows: [SavedWindowReference]) -> SavedWorkspace {
        let now = Date()
        let workspace = SavedWorkspace(
            id: UUID(),
            name: name,
            statusItemSymbolName: nil,
            createdAt: now,
            updatedAt: now,
            windows: windows
        )
        let insertionIndex = workspaces.first?.isDefault == true ? workspaces.index(after: workspaces.startIndex) : workspaces.startIndex
        workspaces.insert(workspace, at: insertionIndex)
        orderDefaultFirst()
        persist()
        return workspace
    }

    func updateWorkspace(id: SavedWorkspace.ID, name: String? = nil, windows: [SavedWindowReference]? = nil) -> SavedWorkspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        if let name, !workspaces[index].isDefault {
            workspaces[index].name = name
        }

        if let windows {
            workspaces[index].windows = windows
        }

        workspaces[index].updatedAt = Date()
        orderDefaultFirst()
        guard let workspace = workspaces.first(where: { $0.id == id }) else {
            return nil
        }
        persist()
        return workspace
    }

    func updateWorkspaceIcon(id: SavedWorkspace.ID, statusItemSymbolName: String?) -> SavedWorkspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        workspaces[index].statusItemSymbolName = statusItemSymbolName
        workspaces[index].updatedAt = Date()
        let workspace = workspaces[index]
        persist()
        return workspace
    }

    func deleteWorkspace(id: SavedWorkspace.ID) {
        guard let workspace = workspaces.first(where: { $0.id == id }),
              !workspace.isDefault else {
            return
        }

        workspaces.removeAll { $0.id == id }
        orderDefaultFirst()
        persist()
    }

    func ensureDefaultWorkspace() {
        let now = Date()
        var didChange = false

        if let firstDefaultIndex = workspaces.firstIndex(where: \.isDefault) {
            if workspaces[firstDefaultIndex].name != Self.defaultWorkspaceName {
                workspaces[firstDefaultIndex].name = Self.defaultWorkspaceName
                didChange = true
            }

            for index in workspaces.indices where index != firstDefaultIndex && workspaces[index].isDefault {
                workspaces[index].isDefault = false
                didChange = true
            }
        } else {
            workspaces.insert(
                SavedWorkspace(
                    id: UUID(),
                    name: Self.defaultWorkspaceName,
                    statusItemSymbolName: nil,
                    createdAt: now,
                    updatedAt: now,
                    windows: [],
                    isDefault: true
                ),
                at: workspaces.startIndex
            )
            didChange = true
        }

        if orderDefaultFirst() {
            didChange = true
        }

        if didChange {
            persist()
        }
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

    @discardableResult
    private func orderDefaultFirst() -> Bool {
        guard let defaultIndex = workspaces.firstIndex(where: \.isDefault),
              defaultIndex != workspaces.startIndex else {
            return false
        }

        let defaultWorkspace = workspaces.remove(at: defaultIndex)
        workspaces.insert(defaultWorkspace, at: workspaces.startIndex)
        return true
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
