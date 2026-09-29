import Foundation

// swiftc HermesPocket/Models.swift Tests/SearchChecks.swift -o /tmp/agentos-search-check && /tmp/agentos-search-check
@main
struct SearchChecks {
    static func main() {
        assert(ChatSearch.snippet(in: "Visit Montréal", query: "montreal") == "Visit Montréal")
        assert(ChatSearch.snippet(in: "🪽 Hermes", query: "HERMES") == "🪽 Hermes")
        assert(ChatSearch.snippet(in: "hello", query: "missing") == nil)
        assert(ChatSearch.snippet(in: "hello", query: "") == nil)
        let snippet = ChatSearch.snippet(in: String(repeating: "a", count: 500) + "needle" + String(repeating: "b", count: 500), query: "needle")!
        assert(snippet.contains("needle") && snippet.count <= 180)
        print("Search checks passed")
    }
}
