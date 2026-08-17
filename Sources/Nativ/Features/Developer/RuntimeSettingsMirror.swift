import Foundation
import NativServerKit

enum RuntimeSettingsMirror {
    struct Mapping {
        let knob: String
        let apply: (inout NativSettings, RuntimeSettingValue) -> Void
    }

    static var mappings: [Mapping] {
        [
        Mapping(
            knob: "max_kv_size",
            apply: { settings, value in
                settings.maxKVSize = value.intValue ?? 0
            }
        ),
        Mapping(
            knob: "kv_bits",
            apply: { settings, value in
                if let bits = value.intValue {
                    settings.kvQuantizationEnabled = true
                    settings.kvBits = Double(bits)
                } else {
                    settings.kvQuantizationEnabled = false
                }
            }
        ),
        Mapping(
            knob: "kv_quant_scheme",
            apply: { settings, value in
                guard let scheme = value.stringValue else { return }
                settings.turboQuantEnabled = scheme == "turboquant"
            }
        ),
        Mapping(
            knob: "kv_group_size",
            apply: { settings, value in
                if let size = value.intValue { settings.kvGroupSize = size }
            }
        ),
        Mapping(
            knob: "quantized_kv_start",
            apply: { settings, value in
                if let start = value.intValue { settings.quantizedKVStart = start }
            }
        ),
        Mapping(
            knob: "apc_enabled",
            apply: { settings, value in
                if let enabled = value.boolValue { settings.prefixCachingEnabled = enabled }
            }
        ),
        Mapping(
            knob: "apc_num_blocks",
            apply: { settings, value in
                if let blocks = value.intValue { settings.prefixCacheBlocks = blocks }
            }
        ),
        Mapping(
            knob: "apc_block_size",
            apply: { settings, value in
                if let size = value.intValue { settings.prefixCacheBlockSize = size }
            }
        ),
        Mapping(
            knob: "spec_draft_model",
            apply: { settings, value in
                let identifier = value.stringValue ?? ""
                settings.draftModelID = identifier
                settings.speculativeDecodingEnabled = !identifier.isEmpty
            }
        ),
        Mapping(
            knob: "spec_draft_kind",
            apply: { settings, value in
                settings.draftKind = value.stringValue ?? "auto"
            }
        )
        ]
    }

    private static func table() -> [String: Mapping] {
        Dictionary(uniqueKeysWithValues: mappings.map { ($0.knob, $0) })
    }

    static var mirroredKnobs: Set<String> {
        Set(mappings.map(\.knob))
    }

    /// Folds server-applied values into a settings snapshot.
    ///
    /// Applied to both the live settings and the snapshot taken at server start,
    /// so `hasSameLaunchConfiguration` sees an identical delta on both sides and
    /// no restart is requested for a change the running server already accepted.
    static func fold(
        _ applied: [String: RuntimeSettingValue],
        into settings: inout NativSettings
    ) -> Bool {
        let table = table()
        var changed = false
        for (knob, value) in applied {
            guard let mapping = table[knob] else { continue }
            mapping.apply(&settings, value)
            changed = true
        }
        return changed
    }
}
