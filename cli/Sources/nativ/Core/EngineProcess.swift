import Foundation

/// Locates the bundled mlx-vlm Python engine so inference can run locally when
/// no server is up. We invoke the engine as `python3 -m mlx_vlm.generate`: the
/// console-script shebangs shipped in the bundle are baked to the build machine
/// and aren't relocatable, but the interpreter and modules are.
enum EngineProcess {
    private static let pythonRelative =
        "Contents/Frameworks/NativServerKit.framework/Versions/A/Resources/mlx-vlm-server/python/bin/python3"

    /// The bundled `python3`, via `NATIV_ENGINE_BIN` override then the app bundle.
    static func locatePython() -> URL? {
        if let override = ProcessInfo.processInfo.environment["NATIV_ENGINE_BIN"] {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return ServerProcess.bundledResource(pythonRelative)
    }
}
