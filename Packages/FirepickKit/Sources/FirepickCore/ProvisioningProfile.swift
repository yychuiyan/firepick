import Foundation

public struct ProvisioningProfileInfo: Equatable, Sendable {
    public var name: String?
    public var teamName: String?
    public var uuid: String?
    public var creationDate: Date?
    public var expirationDate: Date

    public init(
        name: String? = nil,
        teamName: String? = nil,
        uuid: String? = nil,
        creationDate: Date? = nil,
        expirationDate: Date
    ) {
        self.name = name
        self.teamName = teamName
        self.uuid = uuid
        self.creationDate = creationDate
        self.expirationDate = expirationDate
    }
}

public enum ProvisioningProfileParser {
    public static func parse(_ data: Data) throws -> ProvisioningProfileInfo {
        let xmlStart = try requireRange(
            of: Data("<?xml".utf8),
            in: data,
            message: "签名描述文件不包含 XML plist"
        )
        let xmlEnd = try requireRange(
            of: Data("</plist>".utf8),
            in: data,
            options: .backwards,
            message: "签名描述文件不包含 plist 结尾"
        )
        guard xmlStart.lowerBound < xmlEnd.upperBound else {
            throw FirepickError.invalidConfiguration("签名描述文件 plist 范围无效")
        }

        let plistData = data[xmlStart.lowerBound..<xmlEnd.upperBound]
        guard let values = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any],
        let expirationDate = values["ExpirationDate"] as? Date else {
            throw FirepickError.invalidConfiguration("签名描述文件缺少 ExpirationDate")
        }

        return ProvisioningProfileInfo(
            name: values["Name"] as? String,
            teamName: values["TeamName"] as? String,
            uuid: values["UUID"] as? String,
            creationDate: values["CreationDate"] as? Date,
            expirationDate: expirationDate
        )
    }

    private static func requireRange(
        of marker: Data,
        in data: Data,
        options: Data.SearchOptions = [],
        message: String
    ) throws -> Range<Data.Index> {
        guard let range = data.range(of: marker, options: options) else {
            throw FirepickError.invalidConfiguration(message)
        }
        return range
    }
}
