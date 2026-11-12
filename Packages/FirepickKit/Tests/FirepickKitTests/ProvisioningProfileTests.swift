import Foundation
import Testing
@testable import FirepickCore

struct ProvisioningProfileTests {
    @Test
    func parsesExpirationFromCMSWrappedProfile() throws {
        let expiration = Date(timeIntervalSince1970: 2_000_000_000)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "Name": "Firepick Development",
                "TeamName": "Personal Team",
                "UUID": "00000000-0000-0000-0000-000000000001",
                "CreationDate": Date(timeIntervalSince1970: 1_900_000_000),
                "ExpirationDate": expiration,
            ],
            format: .xml,
            options: 0
        )
        let profile = Data("CMS-HEADER".utf8) + plist + Data("CMS-SIGNATURE".utf8)
        let parsed = try ProvisioningProfileParser.parse(profile)

        #expect(parsed.expirationDate == expiration)
        #expect(parsed.teamName == "Personal Team")
        #expect(parsed.name == "Firepick Development")
    }

    @Test
    func rejectsProfileWithoutExpirationDate() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Name": "Broken"],
            format: .xml,
            options: 0
        )
        #expect(throws: FirepickError.self) {
            try ProvisioningProfileParser.parse(plist)
        }
    }
}
