import Foundation

public enum Category: String, Sendable, Equatable, Hashable, CaseIterable {
    case code
    case agentScratch
    case toolchain
    case synced
    case git
    case media
    case documents
    case cache
    case other

    public static let legend: [Category] = [
        .code, .agentScratch, .toolchain, .synced, .git, .media, .documents, .cache,
    ]

    public var label: String {
        switch self {
        case .code: "Code"
        case .agentScratch: "Agent scratch"
        case .toolchain: "Toolchains"
        case .synced: "Synced"
        case .git: "Git"
        case .media: "Media"
        case .documents: "Documents"
        case .cache: "Cache"
        case .other: "Other"
        }
    }
}

public enum Reclaim: String, Sendable, Equatable, Hashable {
    case regenerable
    case syncHistory
    case packageStore
    case buildOutput
    case reinstallable
    case sandboxLayers
    case snapshots
    case trash
    case temporary

    public var label: String {
        switch self {
        case .regenerable: "regenerable"
        case .syncHistory: "sync history"
        case .packageStore: "package store"
        case .buildOutput: "build output"
        case .reinstallable: "reinstallable"
        case .sandboxLayers: "sandbox layers"
        case .snapshots: "snapshots"
        case .trash: "trash"
        case .temporary: "temporary"
        }
    }
}

public func categoryOfName(_ name: String) -> Category? {
    switch name.lowercased() {
    case "src", "code", "projects", "repos", "dev", "work", "workspace", "workspaces",
        "github.com", "gitlab.com", "sites", "development":
        return .code
    case ".codex", ".claude", ".herdr", ".pi", ".cursor", ".aider", ".gemini", ".continue",
        ".windsurf", ".microsandbox", ".omp", ".agents", ".openai", "tries", "worktrees",
        "experiments", "scratch", "playground":
        return .agentScratch
    case ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm", ".bun", ".deno", "go",
        ".gradle", ".m2", ".platformio", "mise", ".mise", ".pyenv", ".nvm", ".gem", "gem",
        ".rbenv", ".espressif", ".arduino15", ".config", ".vscode", ".zig", ".rye", ".conda",
        "anaconda3", "miniconda3", ".opam", ".ghcup", ".stack", ".julia", ".dotnet", ".android",
        ".sdkman", ".volta", ".yarn", ".java", "homebrew", "caskroom":
        return .toolchain
    case "sync", "dropbox", "nextcloud", "google drive", "onedrive", "pclouddrive", "mega",
        ".stversions", "mobile documents", "cloudstorage", "icloud drive":
        return .synced
    case ".git":
        return .git
    case "pictures", "photos", "music", "videos", "movies", "steam", "models", ".ollama",
        ".lmstudio", "games", "wineprefix", "photos library.photoslibrary":
        return .media
    case "documents", "desktop", "downloads", "books", "notes", "obsidian", "public", "templates":
        return .documents
    case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "__pycache__",
        "node_modules", "trash", ".trash", "tmp", ".tmp", "deriveddata":
        return .cache
    case "ios devicesupport", "watchos devicesupport", "tvos devicesupport", "coresimulator":
        return .toolchain
    default:
        return nil
    }
}

public func reclaimOf(
    name: String,
    parent: Category,
    ancestors: [String] = [],
    hasSibling: (String) -> Bool
) -> Reclaim? {
    switch name.lowercased() {
    case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache":
        return .regenerable
    case ".stversions":
        return .syncHistory
    case ".pnpm-store", "pnpm":
        return .packageStore
    case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".turbo", ".parcel-cache":
        return .buildOutput
    case "target" where hasSibling("Cargo.toml"):
        return .buildOutput
    case ".build" where hasSibling("Package.swift"):
        return .buildOutput
    case "node_modules" where hasSibling("package.json"):
        return .reinstallable
    case "pods" where hasSibling("Podfile"):
        return .reinstallable
    case "deriveddata":
        return .buildOutput
    case "ios devicesupport", "watchos devicesupport", "tvos devicesupport":
        return .regenerable
    case "coresimulator":
        return .snapshots
    case "layers" where parent == .agentScratch:
        return .sandboxLayers
    case "snapshots" where parent == .agentScratch:
        return .snapshots
    case "trash", ".trash":
        return .trash
    case "tmp", ".tmp":
        return .temporary
    case "archives" where ancestors.contains("xcode"):
        return nil
    default:
        return nil
    }
}

public func isGitStore(_ node: Node) -> Bool {
    guard node.isDirectory else { return false }
    let names = Set(node.children.map(\.name))
    return names.contains("objects") && names.contains("refs") && names.contains("HEAD")
}

public func classify(_ root: inout Node) {
    root.category = .other
    root.reclaim = nil
    let names = root.children.map(\.name)
    for index in root.children.indices {
        let child = root.children[index]
        let category = categoryOfName(child.name)
            ?? (isGitStore(child) ? Category.git : nil)
            ?? dominantChildCategory(child)
            ?? .other
        let hasSibling = { (wanted: String) in names.contains(wanted) }
        let reclaim = child.isDirectory
            ? reclaimOf(name: child.name, parent: .other, hasSibling: hasSibling)
            : nil
        classifyBelow(&root.children[index], category: category, reclaim: reclaim, ancestors: [])
    }
}

private func classifyBelow(
    _ node: inout Node,
    category: Category,
    reclaim: Reclaim?,
    ancestors: [String]
) {
    node.category = category
    node.reclaim = reclaim
    if node.children.isEmpty { return }
    let names = node.children.map(\.name)
    let nextAncestors = ancestors + [node.name.lowercased()]
    for index in node.children.indices {
        let child = node.children[index]
        let hasSibling = { (wanted: String) in names.contains(wanted) }
        let childCategory: Category
        if child.isDirectory {
            childCategory = categoryOfName(child.name)
                ?? (isGitStore(child) ? Category.git : nil)
                ?? category
        } else {
            childCategory = category
        }
        let own = child.isDirectory
            ? reclaimOf(name: child.name, parent: category, ancestors: nextAncestors, hasSibling: hasSibling)
            : nil
        let childReclaim = reclaim ?? own
        classifyBelow(
            &node.children[index],
            category: childCategory,
            reclaim: childReclaim,
            ancestors: nextAncestors
        )
    }
}

private func dominantChildCategory(_ node: Node) -> Category? {
    var node = node
    for _ in 0..<3 {
        if let category = node.children.first(where: \.isDirectory).flatMap({ _ in
            node.children.lazy.filter(\.isDirectory).compactMap { child -> Category? in
                categoryOfName(child.name) ?? (isGitStore(child) ? .git : nil)
            }.first
        }) {
            return category
        }
        guard let next = node.children.first(where: \.isDirectory) else { return nil }
        node = next
    }
    return nil
}
