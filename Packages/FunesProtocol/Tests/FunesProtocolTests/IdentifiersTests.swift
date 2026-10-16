import Testing
@testable import FunesProtocol

@Suite struct IdentifiersTests {
    // Pinned on purpose: these must never change after the first release.
    @Test func identifiersMatchTheSpec() {
        #expect(Identifiers.macBundleID == "com.funesvault.mac")
        #expect(Identifiers.iOSBundleID == "com.funesvault.ios")
        #expect(Identifiers.appGroup == "group.com.funesvault")
        #expect(Identifiers.supportFolderName == "FunesVault")
        #expect(Identifiers.providerKeychainService == "com.funesvault.provider")
        #expect(Identifiers.mcpKeyPrefix == "fns_mcp_v1_")
        #expect(Identifiers.bonjourServiceType == "_funes._tcp")
    }
}
