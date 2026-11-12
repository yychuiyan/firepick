import Foundation

extension KeyedDecodingContainer {
    func flexibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return value ? "1" : "0" }
        return nil
    }

    func flexibleString(forKey key: Key) throws -> String {
        guard let value = try flexibleStringIfPresent(forKey: key) else {
            throw DecodingError.valueNotFound(
                String.self,
                DecodingError.Context(
                    codingPath: codingPath + [key],
                    debugDescription: "Expected a string-compatible value"
                )
            )
        }
        return value
    }

    func flexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = try? decode(Double.self, forKey: key),
           value.isFinite,
           value.rounded() == value {
            return Int(value)
        }
        return nil
    }

    func flexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = try? decode(Double.self, forKey: key),
           value.isFinite,
           value.rounded() == value {
            return Int64(value)
        }
        return nil
    }

    func flexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
