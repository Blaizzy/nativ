import Foundation
import NativServerKit
import XCTest

final class RuntimeSettingsMirrorTests: XCTestCase {
    private func baseline() -> NativSettings {
        var settings = NativSettings()
        settings.kvQuantizationEnabled = true
        settings.kvBits = 8
        settings.kvGroupSize = 64
        settings.quantizedKVStart = 0
        settings.turboQuantEnabled = false
        settings.maxKVSize = 4096
        settings.prefixCachingEnabled = false
        settings.prefixCacheBlocks = 2048
        settings.prefixCacheBlockSize = 16
        settings.speculativeDecodingEnabled = false
        settings.draftModelID = ""
        settings.draftKind = "auto"
        return settings
    }

    func testFoldAppliesMappedKnobs() {
        var settings = baseline()
        let changed = RuntimeSettingsMirror.fold(
            [
                "kv_bits": .int(4),
                "kv_quant_scheme": .string("turboquant"),
                "max_kv_size": .int(8192),
                "apc_enabled": .bool(true),
                "apc_num_blocks": .int(1024)
            ],
            into: &settings
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(settings.kvBits, 4)
        XCTAssertTrue(settings.kvQuantizationEnabled)
        XCTAssertTrue(settings.turboQuantEnabled)
        XCTAssertEqual(settings.maxKVSize, 8192)
        XCTAssertTrue(settings.prefixCachingEnabled)
        XCTAssertEqual(settings.prefixCacheBlocks, 1024)
    }

    func testNullKVBitsDisablesQuantization() {
        var settings = baseline()
        _ = RuntimeSettingsMirror.fold(["kv_bits": .null], into: &settings)
        XCTAssertFalse(settings.kvQuantizationEnabled)
    }

    func testUnknownKnobsAreIgnored() {
        var settings = baseline()
        let changed = RuntimeSettingsMirror.fold(
            ["token_queue_timeout": .double(1800), "vision_cache_size": .int(40)],
            into: &settings
        )
        XCTAssertFalse(changed, "knobs Nativ does not model must not mark settings dirty")
        XCTAssertEqual(settings, baseline())
    }

    func testDraftModelDrivesSpeculativeDecoding() {
        var settings = baseline()
        _ = RuntimeSettingsMirror.fold(["spec_draft_model": .string("org/draft")], into: &settings)
        XCTAssertTrue(settings.speculativeDecodingEnabled)
        XCTAssertEqual(settings.draftModelID, "org/draft")

        _ = RuntimeSettingsMirror.fold(["spec_draft_model": .null], into: &settings)
        XCTAssertFalse(settings.speculativeDecodingEnabled)
        XCTAssertEqual(settings.draftModelID, "")
    }

    // The safety property the whole design rests on: folding the same values into
    // both sides of the restart comparison must leave it reporting "no restart".
    func testFoldingBothSidesNeverRequestsRestart() {
        let applied: [String: RuntimeSettingValue] = [
            "kv_bits": .int(4),
            "kv_quant_scheme": .string("turboquant"),
            "kv_group_size": .int(32),
            "quantized_kv_start": .int(2),
            "max_kv_size": .int(16384),
            "apc_enabled": .bool(true),
            "apc_num_blocks": .int(512),
            "apc_block_size": .int(32),
            "spec_draft_model": .string("org/draft"),
            "spec_draft_kind": .string("eagle3")
        ]
        var live = baseline()
        var snapshot = baseline()
        XCTAssertTrue(live.hasSameLaunchConfiguration(as: snapshot))

        _ = RuntimeSettingsMirror.fold(applied, into: &live)
        XCTAssertFalse(
            live.hasSameLaunchConfiguration(as: snapshot),
            "sanity: folding only one side must look like a restart is needed"
        )

        _ = RuntimeSettingsMirror.fold(applied, into: &snapshot)
        XCTAssertTrue(
            live.hasSameLaunchConfiguration(as: snapshot),
            "folding both sides must leave the comparison unchanged"
        )
    }

    // Adoption must not mask a genuine restart: a launch-only field still differs.
    func testFoldingDoesNotMaskUnrelatedLaunchChanges() {
        let applied: [String: RuntimeSettingValue] = ["kv_bits": .int(4)]
        var live = baseline()
        var snapshot = baseline()
        live.languageModelID = "org/other-model"

        _ = RuntimeSettingsMirror.fold(applied, into: &live)
        _ = RuntimeSettingsMirror.fold(applied, into: &snapshot)
        XCTAssertFalse(
            live.hasSameLaunchConfiguration(as: snapshot),
            "a model change must still require a restart after adoption"
        )
    }

    func testMappingTableHasNoDuplicateKnobs() {
        XCTAssertEqual(
            RuntimeSettingsMirror.mirroredKnobs.count,
            RuntimeSettingsMirror.mappings.count,
            "duplicate knob names in the mapping table"
        )
    }

    // Every declared mapping must actually move its setting. Without this, a knob
    // silently dropped from `fold` still passes the restart tests -- both sides
    // skip it equally -- while quietly failing to persist.
    func testEveryMappingActuallyMutatesItsSetting() {
        let probes: [String: RuntimeSettingValue] = [
            "max_kv_size": .int(99999),
            "kv_bits": .int(3),
            "kv_quant_scheme": .string("turboquant"),
            "kv_group_size": .int(128),
            "quantized_kv_start": .int(7),
            "apc_enabled": .bool(true),
            "apc_num_blocks": .int(77),
            "apc_block_size": .int(9),
            "spec_draft_model": .string("org/probe-draft"),
            "spec_draft_kind": .string("eagle3")
        ]
        for mapping in RuntimeSettingsMirror.mappings {
            guard let probe = probes[mapping.knob] else {
                XCTAssertTrue(false, "no probe value for \(mapping.knob)")
                continue
            }
            var settings = baseline()
            settings.speculativeDecodingEnabled = true
            settings.draftModelID = "org/original"
            let before = settings
            let changed = RuntimeSettingsMirror.fold([mapping.knob: probe], into: &settings)
            XCTAssertTrue(changed, "\(mapping.knob) reported no change")
            XCTAssertFalse(
                settings == before,
                "\(mapping.knob) is declared in the mapping table but changed nothing"
            )
        }
    }
}
