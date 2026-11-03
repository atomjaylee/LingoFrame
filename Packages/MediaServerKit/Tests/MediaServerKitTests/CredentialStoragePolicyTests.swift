import Security
import Testing
@testable import MediaServerKit

@Test func localBuildsKeepPrivateCredentialsAcrossBuildConfigurations() {
    let adHoc = SecCodeSignatureFlags.adhoc.rawValue
    #expect(CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: true, signingFlags: adHoc))
    #expect(CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: false, signingFlags: adHoc))
    #expect(CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: false, signingFlags: adHoc | 0x10000))
}

@Test func distributionBuildsKeepUsingKeychain() {
    #expect(!CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: false, signingFlags: 0))
    #expect(!CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: false, signingFlags: 0x10000))
}

@Test func unknownReleaseSignatureDoesNotFallBackToFiles() {
    #expect(!CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: false, signingFlags: nil))
}

@Test func debugBuildsRetainTheirExistingCredentialLocation() {
    #expect(CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: true, signingFlags: nil))
    #expect(CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: true, signingFlags: 0))
}
