import FirepickBridge
import FirepickCore
import Foundation
import Security

final class AppPersistence {
  private enum Key {
    static let configurationBaseURL = "configurationBaseURL"
    static let selectedSiteKey = "selectedSiteKey"
    static let playbackPreference = "playbackPreference"
    static let posterSizePreference = "posterSizePreference"
    static let danmakuEnabledByDefault = "danmakuEnabledByDefault"
    static let danmakuOpacity = "danmakuOpacity"
    static let danmakuFontScale = "danmakuFontScale"
    static let danmakuSpeed = "danmakuSpeed"
    static let danmakuAutoMatch = "danmakuAutoMatch"
    static let danmakuCustomAPIBase = "danmakuCustomAPIBase"
    static let danmakuDisplayArea = "danmakuDisplayArea"
    static let sourceConnections = "sourceConnections"
    static let currentConnectionURL = "currentConnectionURL"
    static let liveGroupsCacheDigest = "liveGroupsCacheDigest"
    static let searchHistory = "searchHistory"
    static let simulatorBridgeCredentials = "simulatorBridgeCredentials"
    static let videoOutputPreference = "videoOutputPreference"
    static let decodePreference = "decodePreference"
    static let adSkipPreference = "adSkipPreference"
    static let backgroundPlaybackEnabled = "backgroundPlaybackEnabled"
    static let cloudAdSkipEnabled = "cloudAdSkipEnabled"
    static let incognitoModeEnabled = "incognitoModeEnabled"
    static let multiSourceSearchEnabled = "multiSourceSearchEnabled"
    static let bufferPreference = "bufferPreference"
    static let subtitleFontPreference = "subtitleFontPreference"
    static let subtitleColorPreference = "subtitleColorPreference"
    static let subtitleOutlineEnabled = "subtitleOutlineEnabled"
    static let skipMarks = "skipMarks"
    static let connectionLatencies = "connectionLatencies"
    static let playbackFlagSelections = "playbackFlagSelections"
    static let favoriteLiveChannelIDs = "favoriteLiveChannelIDs"
    static let lastLiveChannelID = "lastLiveChannelID"
    static let lastLiveChannelName = "lastLiveChannelName"
    static let lastLiveGroupName = "lastLiveGroupName"
    static let lastLiveURLIndex = "lastLiveURLIndex"
  }

  private let defaults = UserDefaults.standard
  private let fileManager = FileManager.default
  private let directory: URL
  private let configurationURL: URL
  private let liveGroupsCacheURL: URL

  init() throws {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    directory = support.appending(path: "Firepick", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    configurationURL = directory.appending(path: "configuration.json")
    liveGroupsCacheURL = directory.appending(path: "live-groups-cache.json")
  }

  var configurationData: Data? {
    try? Data(contentsOf: configurationURL)
  }

  var configurationBaseURL: URL? {
    defaults.string(forKey: Key.configurationBaseURL).flatMap(URL.init(string:))
  }

  var selectedSiteKey: String? {
    defaults.string(forKey: Key.selectedSiteKey)
  }

  var playbackPreference: String? {
    defaults.string(forKey: Key.playbackPreference)
  }

  var posterSizePreference: String? {
    defaults.string(forKey: Key.posterSizePreference)
  }

  var danmakuEnabledByDefault: Bool? {
    guard defaults.object(forKey: Key.danmakuEnabledByDefault) != nil else {
      return nil
    }
    return defaults.bool(forKey: Key.danmakuEnabledByDefault)
  }

  var danmakuOpacity: Double? {
    guard defaults.object(forKey: Key.danmakuOpacity) != nil else {
      return nil
    }
    return defaults.double(forKey: Key.danmakuOpacity)
  }

  var danmakuFontScale: Double? {
    guard defaults.object(forKey: Key.danmakuFontScale) != nil else {
      return nil
    }
    return defaults.double(forKey: Key.danmakuFontScale)
  }

  var danmakuSpeed: Double? {
    guard defaults.object(forKey: Key.danmakuSpeed) != nil else {
      return nil
    }
    return defaults.double(forKey: Key.danmakuSpeed)
  }

  var danmakuAutoMatch: Bool? {
    guard defaults.object(forKey: Key.danmakuAutoMatch) != nil else {
      return nil
    }
    return defaults.bool(forKey: Key.danmakuAutoMatch)
  }

  var danmakuCustomAPIBase: String? {
    defaults.string(forKey: Key.danmakuCustomAPIBase)
  }

  var danmakuDisplayArea: String? {
    defaults.string(forKey: Key.danmakuDisplayArea)
  }

  var currentConnectionURL: String? {
    defaults.string(forKey: Key.currentConnectionURL)
  }

  var searchHistory: [String] {
    defaults.stringArray(forKey: Key.searchHistory) ?? []
  }

  func loadSourceConnections() throws -> [SourceConnection] {
    guard let data = defaults.data(forKey: Key.sourceConnections) else {
      return []
    }
    return try JSONDecoder().decode([SourceConnection].self, from: data)
  }

  func saveSourceConnections(_ connections: [SourceConnection]) throws {
    let data = try JSONEncoder().encode(connections)
    defaults.set(data, forKey: Key.sourceConnections)
  }

  func saveCurrentConnectionURL(_ value: String?) {
    if let value {
      defaults.set(value, forKey: Key.currentConnectionURL)
    } else {
      defaults.removeObject(forKey: Key.currentConnectionURL)
    }
  }

  func saveSearchHistory(_ values: [String]) {
    defaults.set(values, forKey: Key.searchHistory)
  }

  func saveConfiguration(_ data: Data, baseURL: URL?) throws {
    try data.write(to: configurationURL, options: .atomic)
    if let baseURL {
      defaults.set(baseURL.absoluteString, forKey: Key.configurationBaseURL)
    } else {
      defaults.removeObject(forKey: Key.configurationBaseURL)
    }
  }

  func clearConfiguration() {
    try? fileManager.removeItem(at: configurationURL)
    defaults.removeObject(forKey: Key.configurationBaseURL)
    defaults.removeObject(forKey: Key.selectedSiteKey)
  }

  func loadLiveGroupsCache(for configurationDigest: String) -> [LiveGroup]? {
    guard !configurationDigest.isEmpty,
      defaults.string(forKey: Key.liveGroupsCacheDigest) == configurationDigest,
      let data = try? Data(contentsOf: liveGroupsCacheURL),
      let groups = try? JSONDecoder().decode([LiveGroup].self, from: data)
    else {
      return nil
    }
    return groups
  }

  func saveLiveGroupsCache(_ groups: [LiveGroup], configurationDigest: String) throws {
    guard !configurationDigest.isEmpty else { return }
    let data = try JSONEncoder().encode(groups)
    try data.write(to: liveGroupsCacheURL, options: .atomic)
    defaults.set(configurationDigest, forKey: Key.liveGroupsCacheDigest)
  }

  func saveSelectedSiteKey(_ key: String?) {
    if let key {
      defaults.set(key, forKey: Key.selectedSiteKey)
    } else {
      defaults.removeObject(forKey: Key.selectedSiteKey)
    }
  }

  func savePlaybackPreference(_ value: String) {
    defaults.set(value, forKey: Key.playbackPreference)
  }

  func savePosterSizePreference(_ value: String) {
    defaults.set(value, forKey: Key.posterSizePreference)
  }

  func saveDanmakuEnabledByDefault(_ value: Bool) {
    defaults.set(value, forKey: Key.danmakuEnabledByDefault)
  }

  func saveDanmakuOpacity(_ value: Double) {
    defaults.set(value, forKey: Key.danmakuOpacity)
  }

  func saveDanmakuFontScale(_ value: Double) {
    defaults.set(value, forKey: Key.danmakuFontScale)
  }

  func saveDanmakuSpeed(_ value: Double) {
    defaults.set(value, forKey: Key.danmakuSpeed)
  }

  func saveDanmakuAutoMatch(_ value: Bool) {
    defaults.set(value, forKey: Key.danmakuAutoMatch)
  }

  func saveDanmakuCustomAPIBase(_ value: String) {
    defaults.set(value, forKey: Key.danmakuCustomAPIBase)
  }

  func saveDanmakuDisplayArea(_ value: String) {
    defaults.set(value, forKey: Key.danmakuDisplayArea)
  }

  var videoOutputPreference: String? { defaults.string(forKey: Key.videoOutputPreference) }
  var decodePreference: String? { defaults.string(forKey: Key.decodePreference) }
  var adSkipPreference: String? { defaults.string(forKey: Key.adSkipPreference) }
  var backgroundPlaybackEnabled: Bool? {
    guard defaults.object(forKey: Key.backgroundPlaybackEnabled) != nil else { return nil }
    return defaults.bool(forKey: Key.backgroundPlaybackEnabled)
  }
  var cloudAdSkipEnabled: Bool? {
    guard defaults.object(forKey: Key.cloudAdSkipEnabled) != nil else { return nil }
    return defaults.bool(forKey: Key.cloudAdSkipEnabled)
  }
  var incognitoModeEnabled: Bool? {
    guard defaults.object(forKey: Key.incognitoModeEnabled) != nil else { return nil }
    return defaults.bool(forKey: Key.incognitoModeEnabled)
  }
  var multiSourceSearchEnabled: Bool? {
    guard defaults.object(forKey: Key.multiSourceSearchEnabled) != nil else { return nil }
    return defaults.bool(forKey: Key.multiSourceSearchEnabled)
  }
  var bufferPreference: String? { defaults.string(forKey: Key.bufferPreference) }
  var subtitleFontPreference: String? { defaults.string(forKey: Key.subtitleFontPreference) }
  var subtitleColorPreference: String? { defaults.string(forKey: Key.subtitleColorPreference) }
  var subtitleOutlineEnabled: Bool? {
    guard defaults.object(forKey: Key.subtitleOutlineEnabled) != nil else { return nil }
    return defaults.bool(forKey: Key.subtitleOutlineEnabled)
  }

  func saveVideoOutputPreference(_ value: String) {
    defaults.set(value, forKey: Key.videoOutputPreference)
  }
  func saveDecodePreference(_ value: String) {
    defaults.set(value, forKey: Key.decodePreference)
  }
  func saveAdSkipPreference(_ value: String) {
    defaults.set(value, forKey: Key.adSkipPreference)
  }
  func saveBackgroundPlaybackEnabled(_ value: Bool) {
    defaults.set(value, forKey: Key.backgroundPlaybackEnabled)
  }
  func saveCloudAdSkipEnabled(_ value: Bool) {
    defaults.set(value, forKey: Key.cloudAdSkipEnabled)
  }
  func saveIncognitoModeEnabled(_ value: Bool) {
    defaults.set(value, forKey: Key.incognitoModeEnabled)
  }
  func saveMultiSourceSearchEnabled(_ value: Bool) {
    defaults.set(value, forKey: Key.multiSourceSearchEnabled)
  }
  func saveBufferPreference(_ value: String) {
    defaults.set(value, forKey: Key.bufferPreference)
  }
  func saveSubtitleFontPreference(_ value: String) {
    defaults.set(value, forKey: Key.subtitleFontPreference)
  }
  func saveSubtitleColorPreference(_ value: String) {
    defaults.set(value, forKey: Key.subtitleColorPreference)
  }
  func saveSubtitleOutlineEnabled(_ value: Bool) {
    defaults.set(value, forKey: Key.subtitleOutlineEnabled)
  }

  func loadSkipMarks() -> [String: AppModel.SkipMark] {
    guard let data = defaults.data(forKey: Key.skipMarks),
      let decoded = try? JSONDecoder().decode([String: AppModel.SkipMark].self, from: data)
    else { return [:] }
    return decoded
  }

  func saveSkipMarks(_ marks: [String: AppModel.SkipMark]) {
    if let data = try? JSONEncoder().encode(marks) {
      defaults.set(data, forKey: Key.skipMarks)
    }
  }

  func loadConnectionLatencies() -> [String: Int] {
    guard let data = defaults.data(forKey: Key.connectionLatencies),
      let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
    else { return [:] }
    return decoded
  }

  func saveConnectionLatencies(_ values: [String: Int]) {
    if let data = try? JSONEncoder().encode(values) {
      defaults.set(data, forKey: Key.connectionLatencies)
    }
  }

  func loadPlaybackFlagSelections() -> [String: String] {
    guard let data = defaults.data(forKey: Key.playbackFlagSelections),
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return decoded
  }

  func savePlaybackFlagSelections(_ values: [String: String]) {
    if let data = try? JSONEncoder().encode(values) {
      defaults.set(data, forKey: Key.playbackFlagSelections)
    }
  }

  func loadFavoriteLiveChannelIDs() -> [String] {
    defaults.stringArray(forKey: Key.favoriteLiveChannelIDs) ?? []
  }

  func saveFavoriteLiveChannelIDs(_ values: [String]) {
    defaults.set(values, forKey: Key.favoriteLiveChannelIDs)
  }

  var lastLiveChannelID: String? { defaults.string(forKey: Key.lastLiveChannelID) }
  var lastLiveChannelName: String? { defaults.string(forKey: Key.lastLiveChannelName) }
  var lastLiveGroupName: String? { defaults.string(forKey: Key.lastLiveGroupName) }
  var lastLiveURLIndex: Int? {
    guard defaults.object(forKey: Key.lastLiveURLIndex) != nil else { return nil }
    return defaults.integer(forKey: Key.lastLiveURLIndex)
  }

  func saveLastLiveChannelID(_ value: String?) {
    defaults.set(value, forKey: Key.lastLiveChannelID)
  }

  func saveLastLiveChannelName(_ value: String?) {
    defaults.set(value, forKey: Key.lastLiveChannelName)
  }

  func saveLastLiveGroupName(_ value: String?) {
    defaults.set(value, forKey: Key.lastLiveGroupName)
  }

  func saveLastLiveURLIndex(_ value: Int) {
    defaults.set(value, forKey: Key.lastLiveURLIndex)
  }

  func loadBridgeCredentials() throws -> BridgeCredentials? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    if status == errSecMissingEntitlement {
      #if targetEnvironment(simulator)
        guard let data = defaults.data(forKey: Key.simulatorBridgeCredentials) else {
          return nil
        }
        return try JSONDecoder().decode(BridgeCredentials.self, from: data)
      #endif
    }
    guard status == errSecSuccess, let data = result as? Data else {
      NSLog("Firepick Keychain read failed: %d", status)
      throw PersistenceError.keychain(status)
    }
    return try JSONDecoder().decode(BridgeCredentials.self, from: data)
  }

  func saveBridgeCredentials(_ credentials: BridgeCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    SecItemDelete(baseQuery as CFDictionary)
    var query = baseQuery
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] =
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecMissingEntitlement {
      #if targetEnvironment(simulator)
        defaults.set(data, forKey: Key.simulatorBridgeCredentials)
        return
      #endif
    }
    guard status == errSecSuccess else {
      NSLog("Firepick Keychain write failed: %d", status)
      throw PersistenceError.keychain(status)
    }
  }

  func clearBridgeCredentials() {
    SecItemDelete(baseQuery as CFDictionary)
    defaults.removeObject(forKey: Key.simulatorBridgeCredentials)
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.firepick.app.bridge",
      kSecAttrAccount as String: "default",
    ]
  }
}

enum PersistenceError: LocalizedError {
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "无法访问钥匙串（\(status)）"
    }
  }
}
