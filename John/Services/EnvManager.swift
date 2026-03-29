import Foundation

enum EnvManager {
    private static let envFileName = ".john.env"
    
    static func loadAPIKey() -> String? {
        // First check environment variable (for development/CI)
        if let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        
        // Search paths in order of priority
        let searchPaths = getSearchPaths()
        
        for path in searchPaths {
            if let key = loadEnvFile(at: path) {
                return key
            }
        }
        
        return nil
    }
    
    private static func getSearchPaths() -> [URL] {
        var paths: [URL] = []
        
        // 1. Home directory (standard location for config files)
        paths.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(envFileName))
        
        // 2. Current working directory (for development)
        paths.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(envFileName))
        
        // 3. App bundle resource directory
        if let resourcePath = Bundle.main.resourcePath {
            paths.append(URL(fileURLWithPath: resourcePath)
                .appendingPathComponent(envFileName))
        }
        
        // 4. App bundle containing directory (for dev builds)
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        paths.append(bundleParent.appendingPathComponent(envFileName))
        
        // 5. App executable directory
        if let executableURL = Bundle.main.executableURL {
            paths.append(executableURL.deletingLastPathComponent().appendingPathComponent(envFileName))
        }
        
        // 6. Project directory (when running from Xcode)
        #if DEBUG
        // Xcode sets this to the built products directory, go up to find project
        if let buildDir = Bundle.main.resourceURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() {
            paths.append(buildDir.appendingPathComponent(envFileName))
            paths.append(buildDir.deletingLastPathComponent().appendingPathComponent(envFileName))
        }
        #endif
        
        // 7. Common development locations
        let projectRoot = URL(fileURLWithPath: "/Volumes/RANGEL/john")
        paths.append(projectRoot.appendingPathComponent(envFileName))
        paths.append(projectRoot.appendingPathComponent("John").appendingPathComponent(envFileName))
        
        return paths
    }
    
    private static func loadEnvFile(at url: URL) -> String? {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return nil
        }
        
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        
        let lines = contents.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            // Parse KEY=VALUE format
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                
                // Remove quotes if present
                let cleanValue = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                
                if key == "OPENROUTER_API_KEY" && !cleanValue.isEmpty {
                    return cleanValue
                }
            }
        }
        
        return nil
    }
    
    static func getEnvFilePath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(envFileName)
    }
    
    static func envFileExists() -> Bool {
        let envPath = getEnvFilePath()
        return FileManager.default.isReadableFile(atPath: envPath.path)
    }
    
    static func getFoundEnvPath() -> String? {
        for path in getSearchPaths() {
            if FileManager.default.isReadableFile(atPath: path.path) {
                if loadEnvFile(at: path) != nil {
                    return path.path
                }
            }
        }
        return nil
    }
}