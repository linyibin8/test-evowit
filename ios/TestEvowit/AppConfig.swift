import Foundation

enum AppConfig {
    static var backendBaseURL: URL {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String
        let fallback = "http://120.197.118.22:21080"
        return URL(string: rawValue ?? fallback) ?? URL(string: fallback)!
    }
}
