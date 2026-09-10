import Foundation
import CryptoKit

public enum RegistryError: Error, Equatable {
    case invalidDefinition, duplicateVersion, duplicateRevision, unknownVersion, referenceMismatch
    case unapproved, inactiveModel, unsupportedNumericPolicy, invalidInputs
}
/// Governance metadata, not authentication or evidence that a formula/fixture passed validation.
public enum DefinitionState: String, Sendable, Codable { case draft, approved, blockedBySpec }
public enum ModelInputRole: String, Sendable, Codable { case required, optional, comparison }
public enum ParameterValue: Sendable, Equatable, Codable {
    case decimal(Money), integer(Int), boolean(Bool), text(String), unspecified(specReference: String)
}
public struct RegistryReference: Sendable, Equatable, Codable, Hashable {
    public let id: String
    public let version: String
    public let revisionID: UUID
    public let contentHash: String
    public init(id: String, version: String, revisionID: UUID, contentHash: String) {
        self.id = id; self.version = version; self.revisionID = revisionID; self.contentHash = contentHash
    }
}

public struct ParameterSet: Sendable, Equatable, Codable {
    public let id: String, version: String
    public let revisionID: UUID
    public let values: [String: ParameterValue]
    public let state: DefinitionState
    public let dispositionReference: String
    public init(id: String, version: String, revisionID: UUID, values: [String: ParameterValue],
                state: DefinitionState, dispositionReference: String) {
        self.id = id; self.version = version; self.revisionID = revisionID; self.values = values
        self.state = state; self.dispositionReference = dispositionReference
    }
    public var reference: RegistryReference {
        var fields = ["parameters.v1", id, version, revisionID.uuidString, state.rawValue, dispositionReference, String(values.count)]
        for key in values.keys.sorted() {
            fields.append(key)
            switch values[key]! {
            case let .decimal(value): fields += ["decimal", value.decimalString]
            case let .integer(value): fields += ["integer", String(value)]
            case let .boolean(value): fields += ["boolean", value ? "true" : "false"]
            case let .text(value): fields += ["text", value]
            case let .unspecified(reference): fields += ["unspecified", reference]
            }
        }
        return RegistryReference(id: id, version: version, revisionID: revisionID, contentHash: fingerprint(fields))
    }
    public func validate() throws {
        guard clean(id), clean(version), clean(dispositionReference), values.keys.allSatisfy(clean) else {
            throw RegistryError.invalidDefinition
        }
        for value in values.values {
            switch value {
            case let .text(text): guard clean(text) else { throw RegistryError.invalidDefinition }
            case let .unspecified(reference):
                guard clean(reference), state != .approved else { throw RegistryError.invalidDefinition }
            default: break
            }
        }
    }
}

public struct ModelInput: Sendable, Equatable, Codable {
    public let name: String, unit: String
    public let role: ModelInputRole
    public let allowsMultiple: Bool
    public init(name: String, unit: String, role: ModelInputRole, allowsMultiple: Bool = false) {
        self.name = name; self.unit = unit; self.role = role; self.allowsMultiple = allowsMultiple
    }
}
public struct ModelOutput: Sendable, Equatable, Codable {
    public let name: String, unit: String
    public init(name: String, unit: String) { self.name = name; self.unit = unit }
}

/// Immutable definition. Changing formula, defaults or governance metadata requires a new version.
/// Parameter content lives independently in the registry; its complete reference is pinned here.
public struct ModelDefinition: Sendable, Equatable, Codable {
    public let id: String, version: String
    public let revisionID: UUID
    public let owner: String, purpose: String
    public let inputs: [ModelInput]
    public let outputs: [ModelOutput]
    public let formula: String, formulaVersion: String, implementationReference: String
    public let defaultParameters: RegistryReference
    public let numericPolicyVersion: String
    public let state: DefinitionState
    public let dispositionReference: String
    public let knownLimitations: [String], testFixtures: [String]
    public let introducedAt: Date, deprecatedAt: Date?

    public init(id: String, version: String, revisionID: UUID, owner: String, purpose: String,
                inputs: [ModelInput], outputs: [ModelOutput], formula: String, formulaVersion: String,
                implementationReference: String, defaultParameters: RegistryReference,
                numericPolicyVersion: String, state: DefinitionState, dispositionReference: String,
                knownLimitations: [String], testFixtures: [String], introducedAt: Date, deprecatedAt: Date? = nil) {
        self.id = id; self.version = version; self.revisionID = revisionID; self.owner = owner; self.purpose = purpose
        self.inputs = inputs; self.outputs = outputs; self.formula = formula; self.formulaVersion = formulaVersion
        self.implementationReference = implementationReference; self.defaultParameters = defaultParameters
        self.numericPolicyVersion = numericPolicyVersion; self.state = state; self.dispositionReference = dispositionReference
        self.knownLimitations = knownLimitations; self.testFixtures = testFixtures
        self.introducedAt = introducedAt; self.deprecatedAt = deprecatedAt
    }
    public var reference: RegistryReference {
        var fields = ["model.v1", id, version, revisionID.uuidString, owner, purpose, formula, formulaVersion,
                      implementationReference, defaultParameters.id, defaultParameters.version,
                      defaultParameters.revisionID.uuidString, defaultParameters.contentHash, numericPolicyVersion,
                      state.rawValue, dispositionReference, String(introducedAt.timeIntervalSince1970),
                      deprecatedAt.map { String($0.timeIntervalSince1970) } ?? "none", String(inputs.count)]
        for input in inputs { fields += [input.name, input.unit, input.role.rawValue, input.allowsMultiple ? "many" : "one"] }
        fields.append(String(outputs.count))
        for output in outputs { fields += [output.name, output.unit] }
        fields.append(String(knownLimitations.count)); fields += knownLimitations
        fields.append(String(testFixtures.count)); fields += testFixtures
        return RegistryReference(id: id, version: version, revisionID: revisionID, contentHash: fingerprint(fields))
    }
    public func validate() throws {
        guard [id, version, owner, purpose, formula, formulaVersion, implementationReference, numericPolicyVersion,
               dispositionReference].allSatisfy(clean), !inputs.isEmpty, !outputs.isEmpty, !testFixtures.isEmpty,
              inputs.allSatisfy({ clean($0.name) && clean($0.unit) }), outputs.allSatisfy({ clean($0.name) && clean($0.unit) }),
              Set(inputs.map(\.name)).count == inputs.count, Set(outputs.map(\.name)).count == outputs.count,
              knownLimitations.allSatisfy(clean), testFixtures.allSatisfy(clean),
              introducedAt.timeIntervalSince1970.isFinite else { throw RegistryError.invalidDefinition }
        if let deprecatedAt {
            guard deprecatedAt.timeIntervalSince1970.isFinite, deprecatedAt > introducedAt else { throw RegistryError.invalidDefinition }
        }
    }
}

/// Only ModelRegistry can construct this complete resolved pair. No latest-version fallback.
/// This is an immutable reproducibility binding, not a runtime calculator or provider qualification.
public struct ResolvedModel: Sendable {
    public let definition: ModelDefinition
    public let parameters: ParameterSet
    fileprivate init(definition: ModelDefinition, parameters: ParameterSet) {
        self.definition = definition; self.parameters = parameters
    }
    public func validateForCalculation(at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, date >= definition.introducedAt,
              definition.deprecatedAt.map({ date < $0 }) ?? true else { throw RegistryError.inactiveModel }
        guard definition.state == .approved, parameters.state == .approved else { throw RegistryError.unapproved }
        guard definition.numericPolicyVersion == Money.numericPolicyVersion else { throw RegistryError.unsupportedNumericPolicy }
    }
    public func validateInputs(_ roles: [String]) throws {
        let counts = Dictionary(grouping: roles, by: { $0 }).mapValues(\.count)
        guard Set(counts.keys).isSubset(of: Set(definition.inputs.map(\.name))) else { throw RegistryError.invalidInputs }
        for input in definition.inputs {
            let count = counts[input.name, default: 0]
            guard (input.role != .required || count > 0), (input.allowsMultiple || count <= 1) else { throw RegistryError.invalidInputs }
        }
    }
}

public actor ModelRegistry {
    private var definitions: [String: [String: ModelDefinition]] = [:]
    private var parameters: [String: [String: ParameterSet]] = [:]
    public init() {}
    public func register(_ parameterSet: ParameterSet) throws {
        try parameterSet.validate()
        guard parameters[parameterSet.id]?[parameterSet.version] == nil else { throw RegistryError.duplicateVersion }
        guard !parameters.values.contains(where: { $0.values.contains(where: { $0.revisionID == parameterSet.revisionID }) }) else {
            throw RegistryError.duplicateRevision
        }
        parameters[parameterSet.id, default: [:]][parameterSet.version] = parameterSet
    }
    public func register(_ definition: ModelDefinition) throws {
        try definition.validate()
        guard definitions[definition.id]?[definition.version] == nil else { throw RegistryError.duplicateVersion }
        guard !definitions.values.contains(where: { $0.values.contains(where: { $0.revisionID == definition.revisionID }) }) else {
            throw RegistryError.duplicateRevision
        }
        _ = try parameterSet(reference: definition.defaultParameters)
        definitions[definition.id, default: [:]][definition.version] = definition
    }
    /// Historical inspection is available even for a draft or deprecated version.
    public func definition(id: String, version: String) throws -> ModelDefinition {
        guard let result = definitions[id]?[version] else { throw RegistryError.unknownVersion }
        return result
    }
    public func parameterSet(reference: RegistryReference) throws -> ParameterSet {
        guard let result = parameters[reference.id]?[reference.version] else { throw RegistryError.unknownVersion }
        guard result.reference == reference else { throw RegistryError.referenceMismatch }
        return result
    }
    public func resolve(reference: RegistryReference, at date: Date) throws -> ResolvedModel {
        let definition = try definition(id: reference.id, version: reference.version)
        guard definition.reference == reference else { throw RegistryError.referenceMismatch }
        let result = try ResolvedModel(definition: definition, parameters: parameterSet(reference: definition.defaultParameters))
        try result.validateForCalculation(at: date)
        return result
    }
}

private func clean(_ text: String) -> Bool {
    !text.isEmpty && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
}
/// Registry-local identity digest: SHA256 over UTF-8 byte-length-prefixed fields.
/// Not the RFC8785 snapshot/backup format; no database schema or provider-config version is implied.
private func fingerprint(_ fields: [String]) -> String {
    var data = Data("registry-identity.v1\n".utf8)
    for field in fields {
        let bytes = Data(field.utf8)
        data.append(contentsOf: "\(bytes.count):".utf8); data.append(bytes)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
