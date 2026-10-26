import Foundation
import Testing
@testable import FunesProtocol

/// The profile's rules (spec/domain/domain-model.md#profile, ADR-0026).
@Suite struct ProfileTests {
    @Test func theCalledNameIsThePreferredElseTheGivenName() {
        #expect(Profile().calledName == nil)
        #expect(Profile(familyName: "Bereciartua").calledName == nil)
        #expect(Profile(givenName: "Martin").calledName == "Martin")
        #expect(Profile(givenName: "Martin", preferredName: "Tincho").calledName == "Tincho")
        #expect(Profile(givenName: "Martin", preferredName: "  ").normalized().calledName == "Martin")
    }

    @Test func normalizingTrimsAndDropsEmptyText() {
        let p = Profile(givenName: " Ana ", familyName: "\n", pronouns: "she/her ", languages: ["pt-BR", " ", "pt-br", "en"],
                        timeZone: " ").normalized()
        #expect(p.givenName == "Ana" && p.familyName == nil && p.pronouns == "she/her")
        #expect(p.languages == ["pt-BR", "en"])
        #expect(p.timeZone == Profile.automaticTimeZone)
    }

    @Test func emptinessIgnoresTheAutomaticTimeZone() {
        #expect(Profile().isEmpty)
        #expect(!Profile(timeZone: "Europe/Lisbon").isEmpty)
        #expect(!Profile(languages: ["en"]).isEmpty)
        #expect(Profile().hasValue(.timeZone))
        #expect(!Profile().hasValue(.name) && Profile(preferredName: "Sam").hasValue(.name))
    }

    @Test func problemsArePerFieldAndNeverCarryText() {
        let p = Profile(givenName: String(repeating: "x", count: 81), pronouns: "they/them",
                        occupation: "Dev, token ghp_abcdefghijklmnopqrstuvwxyz")
        let problems = p.problems()
        #expect(problems[.givenName] == .tooLong(limit: 80))
        #expect(problems[.occupation] == .secret([.githubToken]))
        #expect(problems[.pronouns] == nil)
        #expect(Profile.TextField.allCases.map(\.limit) == [80, 80, 80, 40, 120, 120])
    }

    @Test func languageTagsAndTimeZones() {
        for tag in ["en", "es-AR", "zh-Hant-TW", "sr-Latn", "yue"] { #expect(Profile.isLanguageTag(tag), "\(tag)") }
        for tag in ["e", "english language", "en_US", "en--US", "12", "en-"] { #expect(!Profile.isLanguageTag(tag), "\(tag)") }
        #expect(!Profile(languages: Array(repeating: "en", count: 9)).languagesAreValid)
        #expect(Profile(timeZone: "America/Argentina/Buenos_Aires").timeZoneIsValid)
        #expect(Profile().timeZoneIsValid && !Profile(timeZone: "Nowhere/Land").timeZoneIsValid)
        #expect(Profile().resolvedTimeZone(current: TimeZone(identifier: "Asia/Tokyo")!) == "Asia/Tokyo")
    }

    @Test func fieldsHaveTheirWireSpellingsAndOrder() throws {
        #expect(ProfileField.allCases.map(\.rawValue) == ["name", "pronouns", "languages", "location", "time_zone", "occupation"])
        #expect([ProfileField.occupation, .name, .timeZone].sorted() == [.name, .timeZone, .occupation])
        let data = try JSONEncoder().encode(Profile(givenName: "Martin"))
        #expect(try JSONDecoder().decode(Profile.self, from: data) == Profile(givenName: "Martin"))
    }
}
