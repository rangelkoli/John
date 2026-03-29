import Foundation

enum EnvManager {
    private static let envFileName = ".john.env"
    
    static func loadAPIKey() -> String? {
        // First check environment variable (for development)
        if let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        
        // Then check .john.env in home directory
        let homeEnvPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(envFileName)
        
        if let key = loadEnvFile(at: homeEnvPath) {
            return key
        }
        
        // Then check .john.env in app directory
        if let appPath = Bundle.main.resourceURL?.deletingLastPathComponent() {
            let appEnvPath = appPath.appendingPathComponent(envFileName)
            if let key = loadEnvFile(at: appEnvPath) {
                return key
            }
        }
        
        // Check current working directory (for development)
        let cwdEnvPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(envFileName)
        
        if let key = loadEnvFile(at: cwdEnvPath) {
            return key
        }
        
        return nil
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
}