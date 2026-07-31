import ExtensionFoundation
import Foundation
import NativExtensionSDK

private final class VoiceDictationRuntimeService:
    NSObject,
    NativExtensionXPCProtocol
{
    private let lock = NSLock()
    private var activationContext: NativExtensionActivationContext?

    func activate(
        with contextData: Data,
        reply: @escaping (String?) -> Void
    ) {
        do {
            let context = try JSONDecoder().decode(
                NativExtensionActivationContext.self,
                from: contextData
            )
            guard context.extensionID == "com.nativ.voice-dictation" else {
                reply("The activation context belongs to another extension.")
                return
            }
            lock.withLock {
                activationContext = context
            }
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func deactivate(withReply reply: @escaping () -> Void) {
        lock.withLock {
            activationContext = nil
        }
        reply()
    }

    func performCommand(
        _ commandID: String,
        payload: Data?,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        let isActive = lock.withLock {
            activationContext != nil
        }
        guard isActive else {
            reply(nil, "Audio is not active.")
            return
        }
        reply(nil, nil)
    }
}

@main
private final class VoiceDictationExtensionRuntime: AppExtension {
    private let service = VoiceDictationRuntimeService()

    required init() {}

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "dev.local.Nativ",
            name: "nativ-extension"
        )
    }

    var configuration: ConnectionHandler {
        ConnectionHandler { [service] connection in
            connection.exportedInterface = NSXPCInterface(
                with: NativExtensionXPCProtocol.self
            )
            connection.exportedObject = service
            connection.remoteObjectInterface = NSXPCInterface(
                with: NativExtensionHostXPCProtocol.self
            )
            connection.resume()
            return true
        }
    }
}
