import XCTest
@testable import FluidVoice_Debug

final class FillerWordRemovalTests: XCTestCase {
    private let fillers = SettingsStore.defaultFillerWords

    func testEnglishHesitationIsRemoved() {
        XCTAssertEqual(
            ASRService.removingFillers(from: "Hello um world, uh there.", fillers: self.fillers),
            "Hello world, there."
        )
    }

    func testRussianParasitesAndPhrasesAreRemoved() {
        XCTAssertEqual(
            ASRService.removingFillers(
                from: "Ну вот эти вот какие-то ещё файлы, как бы готовы.",
                fillers: self.fillers
            ),
            "файлы, готовы."
        )
    }

    func testYoAndESpellingsMatch() {
        XCTAssertEqual(
            ASRService.removingFillers(from: "Сделай еще раз, ещё раз.", fillers: ["ещё"]),
            "Сделай раз, раз."
        )
    }

    func testRealWordsStay() {
        XCTAssertEqual(
            ASRService.removingFillers(from: "Это письмо нужно отправить сегодня.", fillers: self.fillers),
            "Это письмо нужно отправить сегодня."
        )
    }
}
