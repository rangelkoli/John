import Foundation

struct AppConfiguration {
    static let shared = AppConfiguration()
    
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let openRouterAPIKey = "openrouter_api_key"
        static let selectedModel = "selected_model"
        static let showInNotch = "show_in_notch"
        static let lastUsedModel = "last_used_model"
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
    
    private init() {}
}

enum DefaultModels {
    static let preferred = "deepseek/deepseek-chat"
    
    static let available: [(name: String, id: String)] = [
        ("DeepSeek Chat", "deepseek/deepseek-chat"),
        ("Claude 3.5 Sonnet", "anthropic/claude-3.5-sonnet"),
        ("GPT-4o", "openai/gpt-4o"),
        ("Gemini 1.5 Pro", "google/gemini-1.5-pro"),
        ("DeepSeek R1", "deepseek/deepseek-reasoner"),
        ("Llama 3.3 70B", "meta-llama/llama-3.3-70b-instruct")
    ]
}