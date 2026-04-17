import Foundation

struct AppConfiguration {
    static let shared = AppConfiguration()
    
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let openRouterAPIKey = "openrouter_api_key"
        static let selectedModel = "selected_model"
        static let showInNotch = "show_in_notch"
        static let lastUsedModel = "last_used_model"
        static let backendHost = "backend_host"
        static let backendPort = "backend_port"
    }
    
    var openRouterAPIKey: String {
        get { defaults.string(forKey: Keys.openRouterAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.openRouterAPIKey) }
    }
    
    var selectedModel: String {
        get { defaults.string(forKey: Keys.selectedModel) ?? DefaultModels.preferred }
        set { defaults.set(newValue, forKey: Keys.selectedModel) }
    }
    
    var showInNotch: Bool {
        get { defaults.object(forKey: Keys.showInNotch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showInNotch) }
    }
    
    var backendHost: String {
        get { defaults.string(forKey: Keys.backendHost) ?? "127.0.0.1" }
        set { defaults.set(newValue, forKey: Keys.backendHost) }
    }
    
    var backendPort: Int {
        get { defaults.integer(forKey: Keys.backendPort) == 0 ? 8765 : defaults.integer(forKey: Keys.backendPort) }
        set { defaults.set(newValue, forKey: Keys.backendPort) }
    }
    
    private init() {}
}

enum DefaultModels {
    static let preferred = "nvidia/nemotron-3-super-120b-a12b:free"
    
    static let available: [(name: String, id: String)] = [
        ("Nemotron 3 Super 120B (Free)", "nvidia/nemotron-3-super-120b-a12b:free"),
        ("DeepSeek Chat", "deepseek/deepseek-chat"),
        ("Claude 3.5 Sonnet", "anthropic/claude-3.5-sonnet"),
        ("GPT-4o", "openai/gpt-4o"),
        ("Gemini 1.5 Pro", "google/gemini-1.5-pro"),
        ("DeepSeek R1", "deepseek/deepseek-reasoner"),
        ("Llama 3.3 70B", "meta-llama/llama-3.3-70b-instruct")
    ]
}