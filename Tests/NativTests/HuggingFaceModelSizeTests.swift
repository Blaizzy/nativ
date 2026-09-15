import Foundation
import XCTest

final class HuggingFaceModelSizeTests: XCTestCase {
    private let ornithParameters: [String: Int64] = ["U32": 34_659_450_880, "BF16": 447_731_056]

    func testPackedEightBitSummaryMatchesRepositoryStorage() throws {
        let safetensors = HuggingFaceSafetensors(parameters: ornithParameters)
        let bytes = try XCTUnwrap(safetensors.sizeBytes(quantizationBits: 8))

        XCTAssertEqual(bytes, 37_721_128_672)
        assertWithinFivePercent(bytes, of: 37_741_392_181)
    }

    func testPackedFourBitSummaryMatchesRepositoryStorage() throws {
        let safetensors = HuggingFaceSafetensors(parameters: ornithParameters)
        let bytes = try XCTUnwrap(safetensors.sizeBytes(quantizationBits: 4))

        XCTAssertEqual(bytes, 20_391_403_232)
        assertWithinFivePercent(bytes, of: 20_418_460_000)
    }

    func testPackedSummaryWithoutQuantizationWidthIsNotEstimated() {
        let safetensors = HuggingFaceSafetensors(parameters: ornithParameters)

        XCTAssertNil(safetensors.sizeBytes(quantizationBits: nil))
    }

    func testUnpackedSummaryChargesTheStorageDataType() throws {
        let safetensors = HuggingFaceSafetensors(parameters: ["BF16": 8_000_000_000])
        let bytes = try XCTUnwrap(safetensors.sizeBytes(quantizationBits: nil))

        XCTAssertEqual(bytes, 16_000_000_000)
    }

    func testIncidentalIntegerTensorsStayUnpacked() throws {
        let safetensors = HuggingFaceSafetensors(parameters: ["BF16": 8_000_000_000, "I32": 1_000_000])
        let bytes = try XCTUnwrap(safetensors.sizeBytes(quantizationBits: 4))

        XCTAssertEqual(bytes, 16_004_000_000)
    }

    func testQuantizedModelThatFitsDoesNotReportAMemoryEstimateOverBudget() throws {
        let model = try decodeModel(
            id: "mlx-community/Ornith-1.5-35B-A3B-8bit",
            parameters: ornithParameters
        )
        let sizeBytes = try XCTUnwrap(model.sizeBytes)
        let estimate = try XCTUnwrap(
            LocalModelMemoryEstimate(modelBytes: Double(sizeBytes), totalMemoryBytes: 96 << 30)
        )

        XCTAssertLessThan(sizeBytes, 40_000_000_000)
        XCTAssertTrue(estimate.isUsable)
    }

    func testOversizedModelStillReportsAnEstimateOverBudget() throws {
        let estimate = try XCTUnwrap(
            LocalModelMemoryEstimate(modelBytes: 180_000_000_000, totalMemoryBytes: 96 << 30)
        )

        XCTAssertFalse(estimate.isUsable)
    }

    func testMemoryBudgetReservesHeadroomFromPhysicalMemory() throws {
        let estimate = try XCTUnwrap(
            LocalModelMemoryEstimate(modelBytes: 1_000, totalMemoryBytes: 96 << 30)
        )

        XCTAssertEqual(estimate.totalMemoryBytes, 96 << 30)
        XCTAssertEqual(estimate.memoryBudgetBytes, UInt64(Double(96 << 30) * 0.8))
    }

    private func decodeModel(id: String, parameters: [String: Int64]) throws -> HuggingFaceModel {
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "downloads": 905,
            "likes": 1,
            "pipeline_tag": "text-generation",
            "library_name": "mlx",
            "tags": ["text-generation"],
            "private": false,
            "gated": false,
            "safetensors": ["parameters": parameters]
        ])
        return try JSONDecoder().decode(HuggingFaceModel.self, from: payload)
    }

    private func assertWithinFivePercent(
        _ value: Int64,
        of expected: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ratio = Double(value) / Double(expected)
        XCTAssertTrue(
            (0.95...1.05).contains(ratio),
            "\(value) is \(String(format: "%.2f", ratio))x of \(expected)",
            file: file,
            line: line
        )
    }
}
