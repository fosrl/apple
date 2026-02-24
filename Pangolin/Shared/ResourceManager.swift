import Combine
import Foundation
import os.log

struct ResourceCategory: Identifiable {
    let id: String
    let name: String
    var resources: [CategorizedResource]
}

struct CategorizedResource: Identifiable {
    var id: Int { resource.resourceId }
    let resource: Resource
    let displayName: String
    var targets: [Target]?
}

struct ResourceGroup: Identifiable {
    let id: String
    let label: String
    var categories: [ResourceCategory]
}

@MainActor
class ResourceManager: ObservableObject {
    @Published var resourceGroups: [ResourceGroup] = []
    @Published var isLoading = false

    private let apiClient: APIClient
    private let authManager: AuthManager
    private var lastOrgId: String?

    private let logger: OSLog = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.cndf.vpn"
        return OSLog(subsystem: subsystem, category: "ResourceManager")
    }()

    init(apiClient: APIClient, authManager: AuthManager) {
        self.apiClient = apiClient
        self.authManager = authManager
    }

    func refreshIfNeeded() async {
        let orgId = authManager.currentOrg?.orgId
        guard let orgId = orgId else {
            resourceGroups = []
            lastOrgId = nil
            return
        }

        // Always refresh when called (menu opened)
        await refreshResources(orgId: orgId)
    }

    func refreshResources(orgId: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.listResources(orgId: orgId)
            let resources = response.resources
            lastOrgId = orgId

            var publicCategories: [String: [CategorizedResource]] = [:]
            var privateCategories: [String: [CategorizedResource]] = [:]

            for resource in resources {
                let (category, displayName) = parseResourceName(resource.name)
                let categorized = CategorizedResource(
                    resource: resource,
                    displayName: displayName,
                    targets: nil
                )

                if resource.http {
                    publicCategories[category, default: []].append(categorized)
                } else {
                    privateCategories[category, default: []].append(categorized)
                }
            }

            var groups: [ResourceGroup] = []

            if !publicCategories.isEmpty {
                let cats = publicCategories
                    .sorted { $0.key < $1.key }
                    .map { ResourceCategory(id: "public-\($0.key)", name: $0.key, resources: $0.value) }
                groups.append(ResourceGroup(id: "public", label: "Public", categories: cats))
            }

            if !privateCategories.isEmpty {
                let cats = privateCategories
                    .sorted { $0.key < $1.key }
                    .map { ResourceCategory(id: "private-\($0.key)", name: $0.key, resources: $0.value) }
                groups.append(ResourceGroup(id: "private", label: "Private", categories: cats))
            }

            resourceGroups = groups
        } catch {
            os_log(
                "Failed to fetch resources: %{public}@",
                log: logger, type: .error,
                error.localizedDescription
            )
            resourceGroups = []
        }
    }

    func fetchTargets(for resourceId: Int) async -> [Target] {
        do {
            let response = try await apiClient.listTargets(resourceId: resourceId)
            return response.targets
        } catch {
            os_log(
                "Failed to fetch targets for resource %d: %{public}@",
                log: logger, type: .error,
                resourceId,
                error.localizedDescription
            )
            return []
        }
    }

    private func parseResourceName(_ name: String) -> (category: String, displayName: String) {
        guard let parenIndex = name.firstIndex(of: ")") else {
            return ("General", name)
        }
        let category = String(name[name.startIndex..<parenIndex]).trimmingCharacters(in: .whitespaces)
        let afterParen = name[name.index(after: parenIndex)...]
        let displayName = String(afterParen).trimmingCharacters(in: .whitespaces)
        if category.isEmpty {
            return ("General", displayName.isEmpty ? name : displayName)
        }
        return (category, displayName.isEmpty ? name : displayName)
    }
}
