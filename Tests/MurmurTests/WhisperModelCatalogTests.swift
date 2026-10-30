import XCTest
@testable import Murmur

final class WhisperModelCatalogTests: XCTestCase {
    // MARK: - Catalog

    func testDefaultIsLargeV3Turbo() {
        XCTAssertEqual(WhisperModelCatalog.defaultVariant, "large-v3-v20240930")
        XCTAssertTrue(WhisperModelCatalog.variants.contains(WhisperModelCatalog.defaultVariant))
    }

    func testLabelsAreHumanReadable() {
        XCTAssertEqual(WhisperModelCatalog.label(for: "large-v3-v20240930"), "large-v3 turbo (best)")
        XCTAssertEqual(WhisperModelCatalog.label(for: "base.en"), "base.en")
        // Unknown variants fall back to the raw name rather than vanishing.
        XCTAssertEqual(WhisperModelCatalog.label(for: "medium"), "medium")
    }

    func testOnlyEnglishVariantsOfSmallModelsAreOffered() {
        // Murmur never sets a language, so WhisperKit forces <|en|> on
        // multilingual models — the .en variants are strictly better there.
        XCTAssertFalse(WhisperModelCatalog.variants.contains("base"))
        XCTAssertTrue(WhisperModelCatalog.variants.contains("tiny.en"))
        XCTAssertTrue(WhisperModelCatalog.variants.contains("small.en"))
    }

    // MARK: - Stored-preference migration

    func testFreshInstallGetsDefault() {
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant(nil, migrationDone: false), "large-v3-v20240930")
    }

    func testOldDefaultBaseIsUpgradedOnce() {
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant("base", migrationDone: false), "large-v3-v20240930")
    }

    func testBaseAfterMigrationIsKeptAsItsEnglishVariant() {
        // A user who deliberately went back to base keeps that size.
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant("base", migrationDone: true), "base.en")
    }

    func testDeliberateChoicesSurviveMigration() {
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant("small.en", migrationDone: false), "small.en")
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant("tiny.en", migrationDone: true), "tiny.en")
    }

    func testDroppedMultilingualVariantMapsToEnglishSibling() {
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant("small", migrationDone: false), "small.en")
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant("tiny", migrationDone: true), "tiny.en")
    }

    func testUnknownStoredVariantFallsBackToDefault() {
        XCTAssertEqual(WhisperModelCatalog.resolveStoredVariant("medium", migrationDone: true), "large-v3-v20240930")
    }
}
