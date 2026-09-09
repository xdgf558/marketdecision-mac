import Foundation

public struct ModelDefinition: Sendable, Equatable {
    public let id: String
    public let version: String
    public let parameterSet: String
    public let inputRoles: Set<String>
    public init(id: String, version: String, parameterSet: String, inputRoles: Set<String>) {
        self.id = id; self.version = version; self.parameterSet = parameterSet; self.inputRoles = inputRoles
    }
}
public enum RegistryError: Error { case invalidDefinition, duplicateVersion, unknownVersion }
public actor ModelRegistry {
    private var definitions: [String: [String: ModelDefinition]] = [:]
    public init() {}
    public func register(_ definition: ModelDefinition) throws {
        guard !definition.id.isEmpty, !definition.version.isEmpty, !definition.parameterSet.isEmpty else { throw RegistryError.invalidDefinition }
        guard definitions[definition.id]?[definition.version] == nil else { throw RegistryError.duplicateVersion }
        definitions[definition.id, default: [:]][definition.version] = definition
    }
    public func definition(id: String, version: String) throws -> ModelDefinition {
        guard let result = definitions[id]?[version] else { throw RegistryError.unknownVersion }
        return result
    }
}
