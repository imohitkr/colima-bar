import Testing

@testable import ColimaBar

@MainActor
@Suite struct StatusIconTests {
    @Test func everySymbolGivesATemplateImage() throws {
        for icon in StatusIcon.allCases {
            let image = try #require(icon.image, "\(icon.rawValue)")
            #expect(image.isTemplate)
        }
    }

    @Test func allSymbolsShareOneSizeInWholePoints() throws {
        let sizes = try StatusIcon.allCases.map { try #require($0.image).size }
        let first = try #require(sizes.first)
        #expect(sizes.allSatisfy { $0 == first })
        #expect(first.width > 0 && first.height > 0)
        #expect(first.width == first.width.rounded())
        #expect(first.height.truncatingRemainder(dividingBy: 2) == 0)
    }
}
