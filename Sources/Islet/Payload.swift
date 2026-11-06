import Foundation

// MARK: - Generic frame wrapper
//
// A tiny wrapper around a decoded JSON object, used by the browser code to read
// incoming frames. Replace it with your own frame type if you already have one.

/// Read-only accessors over a decoded JSON object.
struct Payload {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    init?(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let map = obj as? [String: Any] else { return nil }
        self.raw = map
    }

    var type: String { raw["type"] as? String ?? "" }

    func string(_ key: String) -> String? { raw[key] as? String }

    func int(_ key: String) -> Int? {
        if let v = raw[key] as? Int { return v }
        if let v = raw[key] as? Double { return Int(v) }
        if let v = raw[key] as? NSNumber { return v.intValue }
        if let v = raw[key] as? String { return Int(v) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let v = raw[key] as? Bool { return v }
        if let v = raw[key] as? NSNumber { return v.boolValue }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }

    func maps(_ key: String) -> [[String: Any]] {
        (raw[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    func strings(_ key: String) -> [String] {
        (raw[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

/// JSON helpers. Only `encode` is used by the browser code (for the snapshot size budget).
enum JSONBox {
    static func encode(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func pretty(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                  withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "(no parameters)" }
        return text
    }

    static func oneLine(_ obj: [String: Any]) -> String {
        if obj.isEmpty { return "no parameters" }
        let parts = obj.keys.sorted().map { key -> String in
            let value = obj[key]
            var shown: String
            switch value {
            case let s as String: shown = s
            case let n as NSNumber: shown = n.stringValue
            case is NSNull: shown = "null"
            case let a as [Any]: shown = "\(a.count) items"
            case let d as [String: Any]: shown = "\(d.count) fields"
            default: shown = String(describing: value ?? "")
            }
            shown = shown.replacingOccurrences(of: "\n", with: " ")
            if shown.count > 40 { shown = String(shown.prefix(40)) + "…" }
            return "\(key)=\(shown)"
        }
        return parts.joined(separator: ", ")
    }
}
