import Foundation

public enum NativExtensionHostOperation: String, Codable, Sendable {
    case hostInformation
    case listModels
    case transcribeAudio
    case registerShortcut
    case presentOverlay
    case insertText
    case readStorage
    case writeStorage
}

public struct NativExtensionHostRequest: Codable, Sendable {
    public let requestID: UUID
    public let extensionID: String
    public let operation: NativExtensionHostOperation
    public let payload: Data?

    public init(
        requestID: UUID = UUID(),
        extensionID: String,
        operation: NativExtensionHostOperation,
        payload: Data? = nil
    ) {
        self.requestID = requestID
        self.extensionID = extensionID
        self.operation = operation
        self.payload = payload
    }
}

public struct NativExtensionHostResponse: Codable, Sendable {
    public let requestID: UUID
    public let payload: Data?
    public let errorMessage: String?

    public init(requestID: UUID, payload: Data? = nil, errorMessage: String? = nil) {
        self.requestID = requestID
        self.payload = payload
        self.errorMessage = errorMessage
    }
}

public struct NativExtensionActivationContext: Codable, Sendable {
    public let hostVersion: String
    public let extensionID: String
    public let dataDirectoryPath: String
    public let grantedPermissions: Set<NativExtensionPermission>

    public init(
        hostVersion: String,
        extensionID: String,
        dataDirectoryPath: String,
        grantedPermissions: Set<NativExtensionPermission>
    ) {
        self.hostVersion = hostVersion
        self.extensionID = extensionID
        self.dataDirectoryPath = dataDirectoryPath
        self.grantedPermissions = grantedPermissions
    }
}

public struct NativExtensionHostInformation: Codable, Sendable {
    public let hostVersion: String
    public let extensionID: String
    public let grantedPermissions: Set<NativExtensionPermission>

    public init(
        hostVersion: String,
        extensionID: String,
        grantedPermissions: Set<NativExtensionPermission>
    ) {
        self.hostVersion = hostVersion
        self.extensionID = extensionID
        self.grantedPermissions = grantedPermissions
    }
}

public struct NativExtensionModelDescriptor: Codable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: Set<String>

    public init(id: String, displayName: String, capabilities: Set<String>) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

public struct NativExtensionTranscriptionRequest: Codable, Sendable {
    public let audioData: Data
    public let fileName: String
    public let modelID: String?

    public init(audioData: Data, fileName: String, modelID: String? = nil) {
        self.audioData = audioData
        self.fileName = fileName
        self.modelID = modelID
    }
}

public struct NativExtensionTranscriptionResponse: Codable, Sendable {
    public let text: String
    public let modelID: String

    public init(text: String, modelID: String) {
        self.text = text
        self.modelID = modelID
    }
}

public struct NativExtensionTextInsertionRequest: Codable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct NativExtensionStorageRequest: Codable, Sendable {
    public let key: String
    public let data: Data?

    public init(key: String, data: Data? = nil) {
        self.key = key
        self.data = data
    }
}

@objc public protocol NativExtensionHostXPCProtocol: NSObjectProtocol {
    func performHostRequest(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
}

@objc public protocol NativExtensionXPCProtocol: NSObjectProtocol {
    func activate(
        with contextData: Data,
        reply: @escaping (String?) -> Void
    )
    func deactivate(withReply reply: @escaping () -> Void)
    func performCommand(
        _ commandID: String,
        payload: Data?,
        withReply reply: @escaping (Data?, String?) -> Void
    )
}
