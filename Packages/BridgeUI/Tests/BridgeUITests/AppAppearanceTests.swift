import AppKit
import Testing
@testable import BridgeUI

/// Settings ▸ General ▸ Appearance: Automatic by default, and each choice's NSAppearance.
@Suite("App appearance")
struct AppAppearanceTests {
    @Test func defaultsToAutomatic() {
        #expect(AppAppearance(stored: nil) == .automatic)
        #expect(AppAppearance(stored: "") == .automatic)
        #expect(AppAppearance(stored: "Dark") == .automatic)
        #expect(AppAppearance(stored: "sepia") == .automatic)
    }

    @Test func roundTrips() {
        for choice in AppAppearance.allCases {
            #expect(AppAppearance(stored: choice.rawValue) == choice)
        }
        #expect(AppAppearance.allCases == [.automatic, .light, .dark])
    }

    @Test func mapsToAppearances() {
        #expect(AppAppearance.automatic.appearanceName == nil)
        #expect(AppAppearance.light.appearanceName == .aqua)
        #expect(AppAppearance.dark.appearanceName == .darkAqua)
        // Each forced name is one AppKit can load.
        #expect(NSAppearance(named: .aqua)?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(NSAppearance(named: .darkAqua)?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}
