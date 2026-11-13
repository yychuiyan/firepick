import CommonCrypto
import CryptoKit
import Foundation
import Security

/// FongMi/CatVod `Crypto` parity used by QuickJS globals `aesX` / `desX` / `rsaX`.
enum CatVodCrypto {
  private static let aesBlockSize = 16
  private static let desBlockSize = 8
  private static let desEdeTwoKeySize = 16
  private static let desEdeThreeKeySize = 24
  private static let gcmTagSize = 16

  static func aes(
    mode: String,
    encrypt: Bool,
    input: String,
    inputBase64: Bool,
    key: String,
    iv: String,
    outputBase64: Bool
  ) -> String {
    do {
      if mode.uppercased().contains("GCM") {
        return try aesGCM(
          encrypt: encrypt,
          input: input,
          inputBase64: inputBase64,
          keyHex: key,
          ivHex: iv,
          outputBase64: outputBase64
        )
      }
      let keyBytes = padParameter(Data(key.utf8), minLength: aesBlockSize)
      let ivBytes = getIV(iv, blockSize: aesBlockSize)
      let transformation = aesTransformation(mode)
      let data = decode(input, base64: inputBase64)
      let output = try cryptAES(
        data,
        key: keyBytes,
        iv: ivBytes,
        encrypt: encrypt,
        ecb: transformation.contains("/ECB/")
      )
      return encode(output, base64: outputBase64)
    } catch {
      return ""
    }
  }

  static func des(
    mode: String,
    encrypt: Bool,
    input: String,
    inputBase64: Bool,
    key: String,
    iv: String,
    outputBase64: Bool
  ) -> String {
    do {
      let keyBytes = desEdeKey(key)
      let ivBytes = getIV(iv, blockSize: desBlockSize)
      let data = decode(input, base64: inputBase64)
      let useCBC = mode.uppercased().contains("CBC")
      let output = try crypt3DES(
        data,
        key: keyBytes,
        iv: ivBytes,
        encrypt: encrypt,
        cbc: useCBC
      )
      return encode(output, base64: outputBase64)
    } catch {
      return ""
    }
  }

  static func rsa(
    mode: String,
    publicKey: Bool,
    encrypt: Bool,
    input: String,
    inputBase64: Bool,
    key: String,
    outputBase64: Bool
  ) -> String {
    do {
      let rsaMode = try RSAMode.parse(mode)
      guard let secKey = makeRSAKey(pem: key, publicKey: publicKey) else { return "" }
      let data = decode(input, base64: inputBase64)
      let output = try transformRSA(
        data,
        key: secKey,
        mode: rsaMode,
        encrypt: encrypt
      )
      return encode(output, base64: outputBase64)
    } catch {
      return ""
    }
  }

  // MARK: - AES

  private static func aesTransformation(_ mode: String) -> String {
    if mode.hasPrefix("AES/CBC") { return "AES/CBC/PKCS5Padding" }
    if mode.hasPrefix("AES/ECB") { return "AES/ECB/PKCS5Padding" }
    return mode + "Padding"
  }

  private static func cryptAES(
    _ data: Data,
    key: Data,
    iv: Data?,
    encrypt: Bool,
    ecb: Bool
  ) throws -> Data {
    if !ecb, iv == nil {
      throw CryptoError.missingIV
    }
    var options = CCOptions(kCCOptionPKCS7Padding)
    if ecb {
      options |= CCOptions(kCCOptionECBMode)
    }
    let operation = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
    let capacity = data.count + kCCBlockSizeAES128
    var output = Data(count: capacity)
    var outputLength = 0
    let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
      data.withUnsafeBytes { dataBytes in
        key.withUnsafeBytes { keyBytes in
          func run(_ ivPointer: UnsafeRawPointer?) -> CCCryptorStatus {
            CCCrypt(
              operation,
              CCAlgorithm(kCCAlgorithmAES),
              options,
              keyBytes.baseAddress,
              key.count,
              ivPointer,
              dataBytes.baseAddress,
              data.count,
              outputBytes.baseAddress,
              capacity,
              &outputLength
            )
          }
          if let iv {
            return iv.withUnsafeBytes { run($0.baseAddress) }
          }
          return run(nil)
        }
      }
    }
    guard status == kCCSuccess else { throw CryptoError.cryptFailed(status) }
    output.removeSubrange(outputLength..<output.count)
    return output
  }

  private static func aesGCM(
    encrypt: Bool,
    input: String,
    inputBase64: Bool,
    keyHex: String,
    ivHex: String,
    outputBase64: Bool
  ) throws -> String {
    let keyData = try fromHex(keyHex)
    let ivData = try fromHex(ivHex)
    let key = SymmetricKey(data: keyData)
    let nonce = try AES.GCM.Nonce(data: ivData)

    if encrypt {
      let plain: Data
      if inputBase64 {
        plain = decode(input, base64: true)
      } else {
        plain = Data(input.utf8)
      }
      let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce)
      guard let combined = sealed.combined else { return "" }
      // Java packs ciphertext||tag; CryptoKit combined is nonce||ciphertext||tag.
      // FongMi GCM uses Cipher.doFinal which returns ciphertext||tag only.
      let cipherAndTag = combined.dropFirst(ivData.count)
      if outputBase64 {
        return Data(cipherAndTag).base64EncodedString()
      }
      return toHex(Data(cipherAndTag))
    }

    let raw: Data
    if inputBase64 {
      raw = decode(input, base64: true)
    } else {
      raw = try fromHex(input)
    }
    guard raw.count >= gcmTagSize else { return "" }
    let cipher = raw.dropLast(gcmTagSize)
    let tag = raw.suffix(gcmTagSize)
    let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
    let plain = try AES.GCM.open(sealed, using: key)
    return encode(plain, base64: outputBase64)
  }

  // MARK: - 3DES

  private static func crypt3DES(
    _ data: Data,
    key: Data,
    iv: Data?,
    encrypt: Bool,
    cbc: Bool
  ) throws -> Data {
    if cbc, iv == nil {
      throw CryptoError.missingIV
    }
    var options = CCOptions(kCCOptionPKCS7Padding)
    if !cbc {
      options |= CCOptions(kCCOptionECBMode)
    }
    let operation = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
    let capacity = data.count + kCCBlockSize3DES
    var output = Data(count: capacity)
    var outputLength = 0
    let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
      data.withUnsafeBytes { dataBytes in
        key.withUnsafeBytes { keyBytes in
          func run(_ ivPointer: UnsafeRawPointer?) -> CCCryptorStatus {
            CCCrypt(
              operation,
              CCAlgorithm(kCCAlgorithm3DES),
              options,
              keyBytes.baseAddress,
              key.count,
              ivPointer,
              dataBytes.baseAddress,
              data.count,
              outputBytes.baseAddress,
              capacity,
              &outputLength
            )
          }
          if let iv {
            return iv.withUnsafeBytes { run($0.baseAddress) }
          }
          return run(nil)
        }
      }
    }
    guard status == kCCSuccess else { throw CryptoError.cryptFailed(status) }
    output.removeSubrange(outputLength..<output.count)
    return output
  }

  private static func desEdeKey(_ key: String) -> Data {
    let bytes = padParameter(Data(key.utf8), minLength: desEdeTwoKeySize)
    if bytes.count != desEdeTwoKeySize {
      return bytes.count > desEdeThreeKeySize
        ? bytes.prefix(desEdeThreeKeySize)
        : bytes
    }
    var expanded = bytes
    expanded.append(bytes.prefix(desBlockSize))
    return expanded
  }

  // MARK: - RSA

  private enum RSAMode {
    case pkcs1
    case none
    case oaepSHA1

    var paddingOverhead: Int {
      switch self {
      case .pkcs1: return 11
      case .none: return 0
      case .oaepSHA1: return 42
      }
    }

    var algorithm: SecKeyAlgorithm {
      switch self {
      case .pkcs1: return .rsaEncryptionPKCS1
      case .none: return .rsaEncryptionRaw
      case .oaepSHA1: return .rsaEncryptionOAEPSHA1
      }
    }

    static func parse(_ mode: String) throws -> RSAMode {
      switch mode {
      case "RSA/PKCS1": return .pkcs1
      case "RSA/None/NoPadding": return .none
      case "RSA/None/OAEPPadding": return .oaepSHA1
      default: throw CryptoError.unsupportedRSA(mode)
      }
    }
  }

  private static func makeRSAKey(pem: String, publicKey: Bool) -> SecKey? {
    let begin = publicKey ? "-----BEGIN PUBLIC KEY-----" : "-----BEGIN PRIVATE KEY-----"
    let end = publicKey ? "-----END PUBLIC KEY-----" : "-----END PRIVATE KEY-----"
    let cleaned = pem
      .replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: begin, with: "")
      .replacingOccurrences(of: end, with: "")
    guard let data = Data(base64Encoded: cleaned) else { return nil }
    let attrs: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: publicKey ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate,
    ]
    return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil)
  }

  private static func transformRSA(
    _ input: Data,
    key: SecKey,
    mode: RSAMode,
    encrypt: Bool
  ) throws -> Data {
    if input.isEmpty { return input }
    let blockSize = SecKeyGetBlockSize(key)
    let inputBlockSize = encrypt ? blockSize - mode.paddingOverhead : blockSize
    guard inputBlockSize > 0 else { throw CryptoError.cryptFailed(-1) }
    var output = Data()
    var offset = 0
    while offset < input.count {
      let length = min(inputBlockSize, input.count - offset)
      var chunk = input.subdata(in: offset..<(offset + length))
      if mode == .none, length != blockSize {
        var padded = Data(count: blockSize)
        padded.replaceSubrange((blockSize - length)..<blockSize, with: chunk)
        chunk = padded
      }
      var error: Unmanaged<CFError>?
      let result: CFData?
      if encrypt {
        result = SecKeyCreateEncryptedData(
          key,
          mode.algorithm,
          chunk as CFData,
          &error
        )
      } else {
        result = SecKeyCreateDecryptedData(
          key,
          mode.algorithm,
          chunk as CFData,
          &error
        )
      }
      guard let result else { throw CryptoError.cryptFailed(-2) }
      output.append(result as Data)
      offset += length
    }
    return output
  }

  // MARK: - Helpers

  private static func getIV(_ iv: String, blockSize: Int) -> Data? {
    if iv.isEmpty { return nil }
    return padParameter(Data(iv.utf8), minLength: blockSize)
  }

  private static func padParameter(_ value: Data, minLength: Int) -> Data {
    if value.count >= minLength { return value }
    var padded = value
    padded.append(Data(count: minLength - value.count))
    return padded
  }

  private static func decode(_ input: String, base64: Bool) -> Data {
    if base64 {
      let normalized = input
        .replacingOccurrences(of: "_", with: "/")
        .replacingOccurrences(of: "-", with: "+")
      return Data(base64Encoded: normalized) ?? Data()
    }
    return Data(input.utf8)
  }

  private static func encode(_ output: Data, base64: Bool) -> String {
    if base64 {
      return output.base64EncodedString()
    }
    return String(data: output, encoding: .utf8) ?? ""
  }

  private static func toHex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func fromHex(_ value: String) throws -> Data {
    let clean = value.filter { !$0.isWhitespace }
    guard clean.count.isMultiple(of: 2) else { throw CryptoError.invalidHex }
    var data = Data()
    var index = clean.startIndex
    while index < clean.endIndex {
      let next = clean.index(index, offsetBy: 2)
      guard let byte = UInt8(clean[index..<next], radix: 16) else { throw CryptoError.invalidHex }
      data.append(byte)
      index = next
    }
    return data
  }

  private enum CryptoError: Error {
    case missingIV
    case cryptFailed(Int32)
    case unsupportedRSA(String)
    case invalidHex
  }
}
