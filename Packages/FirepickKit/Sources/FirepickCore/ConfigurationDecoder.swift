import CommonCrypto
import Foundation

public enum ConfigurationDecoder {
    public static func normalize(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw FirepickError.invalidConfiguration("配置文件为空")
        }

        var text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "{" || text.first == "[" {
            if let data = text.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return data
            }
            return Data(sanitizeJSON(text).utf8)
        }
        if text.hasPrefix("#EXTM3U") || text.contains("#genre#") {
            return Data(text.utf8)
        }

        if text.contains("**"), let decoded = decodeBase64Prefixed(text) {
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("2423") {
            text = try decodeLegacyCBC(text)
        }
        text = sanitizeJSON(unwrapJSONObject(in: text))
        return Data(text.utf8)
    }

    private static func decodeBase64Prefixed(_ text: String) -> String? {
        guard let range = text.range(of: #"^[A-Za-z0-9]{8}\*\*"#, options: .regularExpression) else {
            return nil
        }
        let encoded = String(text[range.upperBound...])
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Mirrors `com.github.catvod.utils.Decoder.cbc`.
    private static func decodeLegacyCBC(_ source: String) throws -> String {
        guard let metadataData = hexData(source) else {
            throw FirepickError.invalidConfiguration("加密配置不是十六进制")
        }
        // Android constructs this with `new String(bytes, UTF_8)`, which
        // replaces invalid bytes instead of failing the whole decode.
        let metadata = String(decoding: metadataData, as: UTF8.self).lowercased()
        guard
              let keyStartRange = metadata.range(of: "$#"),
              let keyEndRange = metadata.range(of: "#$", range: keyStartRange.upperBound..<metadata.endIndex),
              metadata.count >= 13,
              let marker = source.range(of: "2324") else {
            throw FirepickError.invalidConfiguration("加密配置元数据无效")
        }

        let key = padded(String(metadata[keyStartRange.upperBound..<keyEndRange.lowerBound]))
        let iv = padded(String(metadata.suffix(13)))
        let cipherStart = marker.upperBound
        guard source.distance(from: source.startIndex, to: cipherStart) + 26 < source.count else {
            throw FirepickError.invalidConfiguration("加密配置正文无效")
        }
        let cipherEnd = source.index(source.endIndex, offsetBy: -26)
        let cipherText = String(source[cipherStart..<cipherEnd])
        guard let cipher = hexData(cipherText) else {
            throw FirepickError.invalidConfiguration("加密配置密文无效")
        }
        let plain = try aesCBCDecrypt(cipher, key: key, iv: iv)
        guard let json = String(data: plain, encoding: .utf8) else {
            throw FirepickError.invalidConfiguration("解密配置不是 UTF-8")
        }
        return json
    }

    private static func padded(_ value: String) -> Data {
        let suffix = String(repeating: "0", count: 16)
        let result = value.count >= 16 ? String(value.prefix(16)) : value + suffix.prefix(16 - value.count)
        return Data(result.utf8)
    }

    private static func hexData(_ string: String) -> Data? {
        let clean = string.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw FirepickError.invalidConfiguration("AES-CBC 解密失败：\(status)")
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private static func unwrapJSONObject(in text: String) -> String {
        guard !text.hasPrefix("{"),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return text
        }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return text
        }
        return candidate
    }

    /// TVBox sources commonly use `//` and `/* */` comments. JSONSerialization
    /// is stricter than Android's Gson, so remove comments and redundant
    /// trailing commas only when outside string literals.
    private static func sanitizeJSON(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        let chars = Array(input)
        var index = 0
        var inString = false
        var escaped = false

        while index < chars.count {
            let char = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if inString {
                output.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if char == "\"" {
                inString = true
                output.append(char)
                index += 1
                continue
            }
            if char == "/", next == "/" {
                index += 2
                while index < chars.count, !chars[index].isNewline { index += 1 }
                continue
            }
            if char == "#" {
                while index < chars.count, !chars[index].isNewline { index += 1 }
                continue
            }
            if char == "/", next == "*" {
                index += 2
                while index + 1 < chars.count,
                      !(chars[index] == "*" && chars[index + 1] == "/") {
                    index += 1
                }
                index = min(chars.count, index + 2)
                continue
            }
            output.append(char)
            index += 1
        }

        var cleaned = ""
        cleaned.reserveCapacity(output.count)
        let sanitizedChars = Array(output)
        index = 0
        inString = false
        escaped = false
        while index < sanitizedChars.count {
            let char = sanitizedChars[index]
            if inString {
                cleaned.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if char == "\"" {
                inString = true
                cleaned.append(char)
                index += 1
                continue
            }
            if char == "," {
                var lookAhead = index + 1
                while lookAhead < sanitizedChars.count,
                      sanitizedChars[lookAhead].isWhitespace {
                    lookAhead += 1
                }
                if lookAhead < sanitizedChars.count,
                   sanitizedChars[lookAhead] == "}" || sanitizedChars[lookAhead] == "]" {
                    index += 1
                    continue
                }
            }
            cleaned.append(char)
            index += 1
        }
        return cleaned
    }
}

