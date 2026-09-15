// Uses Nativ's existing read-only sensor implementation. Unsupported rails remain null.
import Foundation

@main
struct VoicePowerProbe {
    static func main() {
        let sampler = SystemSensorSampler()
        let seconds = Int(CommandLine.arguments.dropFirst().first ?? "15") ?? 15
        for _ in 0...seconds {
            let p = sampler.powerMetrics()
            let t = sampler.thermalMetrics()
            let object: [String: Any] = [
                "unix_seconds": Date().timeIntervalSince1970,
                "cpu_w": p.cpuWatts as Any? ?? NSNull(),
                "gpu_w": p.gpuWatts as Any? ?? NSNull(),
                "ane_w": p.aneWatts as Any? ?? NSNull(),
                "dram_w": p.dramWatts as Any? ?? NSNull(),
                "soc_w": p.socWatts as Any? ?? NSNull(),
                "system_input_w": p.systemInputWatts as Any? ?? NSNull(),
                "die_c": t.dieTemperatureCelsius as Any? ?? NSNull(),
                "thermal_pressure": t.thermalPressureLabel
            ]
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
