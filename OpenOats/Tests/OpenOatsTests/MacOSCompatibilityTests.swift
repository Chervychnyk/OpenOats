import XCTest
@testable import OpenOatsKit

final class MacOSCompatibilityTests: XCTestCase {
    func testEveryModelButRemovedQwen3IsSupported() {
        for major in [14, 15, 26] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
            for model in TranscriptionModel.allCases {
                XCTAssertEqual(model.isSupported(on: version), model != .qwen3ASR06B, model.rawValue)
            }
        }
    }

    func testLiveAndBatchPickersOnlyOfferAvailableBackends() {
        XCTAssertTrue(TranscriptionModel.availableCases.allSatisfy(\.isAvailable))
        XCTAssertTrue(TranscriptionModel.batchSuitableModels.allSatisfy(\.isAvailable))
        XCTAssertFalse(TranscriptionModel.availableCases.contains(.qwen3ASR06B))
        XCTAssertTrue(TranscriptionModel.availableCases.contains(.parakeetV2))
        XCTAssertTrue(TranscriptionModel.availableCases.contains(.parakeetUltra))
        XCTAssertTrue(TranscriptionModel.batchSuitableModels.contains(.whisperLargeV3Turbo))
    }
}
