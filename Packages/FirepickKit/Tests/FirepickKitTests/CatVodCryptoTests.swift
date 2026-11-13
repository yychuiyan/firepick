import Foundation
import Testing
@testable import FirepickProvider

struct CatVodCryptoTests {
  @Test
  func aesCBCRoundTripMatchesFongMiSignature() {
    let plain = "firepick-aes-smoke"
    let key = "0123456789abcdef"
    let iv = "fedcba9876543210"
    let cipher = CatVodCrypto.aes(
      mode: "AES/CBC/PKCS7",
      encrypt: true,
      input: plain,
      inputBase64: false,
      key: key,
      iv: iv,
      outputBase64: true
    )
    #expect(!cipher.isEmpty)

    let decoded = CatVodCrypto.aes(
      mode: "AES/CBC/PKCS7",
      encrypt: false,
      input: cipher,
      inputBase64: true,
      key: key,
      iv: iv,
      outputBase64: false
    )
    #expect(decoded == plain)
  }

  @Test
  func aesECBEncryptDecrypt() {
    let plain = "ecb-mode-payload!"
    let key = "0123456789abcdef"
    let cipher = CatVodCrypto.aes(
      mode: "AES/ECB/PKCS7",
      encrypt: true,
      input: plain,
      inputBase64: false,
      key: key,
      iv: "",
      outputBase64: true
    )
    let decoded = CatVodCrypto.aes(
      mode: "AES/ECB/PKCS7",
      encrypt: false,
      input: cipher,
      inputBase64: true,
      key: key,
      iv: "",
      outputBase64: false
    )
    #expect(decoded == plain)
  }

  @Test
  func desCBCRoundTrip() {
    let plain = "des-ede-smoke"
    let key = "0123456789abcdef"
    let iv = "abcdefgh"
    let cipher = CatVodCrypto.des(
      mode: "DESede/CBC/PKCS7",
      encrypt: true,
      input: plain,
      inputBase64: false,
      key: key,
      iv: iv,
      outputBase64: true
    )
    #expect(!cipher.isEmpty)
    let decoded = CatVodCrypto.des(
      mode: "DESede/CBC/PKCS7",
      encrypt: false,
      input: cipher,
      inputBase64: true,
      key: key,
      iv: iv,
      outputBase64: false
    )
    #expect(decoded == plain)
  }
}
