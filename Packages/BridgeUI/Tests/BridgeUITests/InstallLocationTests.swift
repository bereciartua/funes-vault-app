import Foundation
import Testing
@testable import BridgeUI

/// Ported from EK Bridge's InstallLocationTests (Move to Applications, FR-O-03): where the app runs
/// from, where the copy goes, and how the prompt names the place.
@Suite("Install location")
struct InstallLocationTests {
    static let home = "/Users/someone"

    func classify(_ path: String, original: String? = nil) -> InstallLocation {
        InstallLocation.classify(bundlePath: path, home: Self.home, originalPath: original)
    }

    @Test func classifies() {
        #expect(classify("/Applications/FunesVault.app") == .applications)
        #expect(classify("/Applications/Utilities/FunesVault.app") == .applications)
        #expect(classify("/Users/someone/Applications/FunesVault.app") == .applications)
        #expect(classify("/Volumes/Work/Applications/FunesVault.app") == .applications)
        #expect(classify("/Volumes/Funes Vault/FunesVault.app") == .diskImage(volume: "/Volumes/Funes Vault"))
        #expect(classify("/Volumes/Funes Vault/./FunesVault.app") == .diskImage(volume: "/Volumes/Funes Vault"))
        #expect(classify("/Users/someone/Downloads/FunesVault.app") == .elsewhere(path: "/Users/someone/Downloads/FunesVault.app"))
        #expect(classify("/Applications.old/FunesVault.app") == .elsewhere(path: "/Applications.old/FunesVault.app"))
        #expect(classify("/Users/other/Applications/FunesVault.app") == .elsewhere(path: "/Users/other/Applications/FunesVault.app"))
    }

    @Test func translocation() {
        let translocated = "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/FunesVault.app"
        #expect(classify(translocated, original: "/Users/someone/Downloads/FunesVault.app")
                == .translocated(original: "/Users/someone/Downloads/FunesVault.app"))
        #expect(classify(translocated) == .translocated(original: nil))
        #expect(classify(translocated).sourcePath(running: translocated) == nil)
        #expect(classify("/Volumes/Funes Vault/FunesVault.app").sourcePath(running: "/Volumes/Funes Vault/FunesVault.app")
                == "/Volumes/Funes Vault/FunesVault.app")
        #expect(classify(translocated, original: "/Volumes/Funes Vault/FunesVault.app").placeName(home: Self.home)
                == "the disk image")
        #expect(classify(translocated).placeName(home: Self.home) == "a temporary location")
        #expect(classify(translocated, original: "/Volumes/Funes Vault/FunesVault.app").leavesVolume == "/Volumes/Funes Vault")
    }

    @Test func destinationAndWording() {
        #expect(InstallLocation.destination(bundleFileName: "FunesVault.app", applicationsWritable: true, home: Self.home)
                == "/Applications/FunesVault.app")
        #expect(InstallLocation.destination(bundleFileName: "FunesVault.app", applicationsWritable: false, home: Self.home)
                == "/Users/someone/Applications/FunesVault.app")
        #expect(classify("/Users/someone/Downloads/FunesVault.app").placeName(home: Self.home) == "Downloads")
        #expect(classify("/Users/someone/Downloads/test/FunesVault.app").placeName(home: Self.home) == "Downloads")
        #expect(classify("/Users/someone/Desktop/FunesVault.app").placeName(home: Self.home) == "the “Desktop” folder")
        #expect(classify("/Volumes/Funes Vault/FunesVault.app").placeName(home: Self.home) == "the disk image")
        #expect(classify("/Volumes/Funes Vault/FunesVault.app").leavesVolume == "/Volumes/Funes Vault")
        #expect(classify("/Users/someone/Downloads/FunesVault.app").leavesVolume == nil)
    }
}
