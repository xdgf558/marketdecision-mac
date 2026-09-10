import Foundation
import CryptoKit
import CoreDomain

public enum SnapshotError: Error, Equatable {
    case invalidIdentity, unsupportedFormat, duplicateObject, duplicateProperty, missingReference, hashMismatch, cycle
    case retentionDenied, resourceLimit, unsafeArchive, credentialMaterial, stalePlan, unknownPlan, approvalMismatch, protectedObject
}

/// Restricted RFC8785 profile: strings, booleans, null, arrays and objects. Decimal and
/// integers are strings; arbitrary JSON-number parsing is deliberately unavailable.
/// Members are an array so Swift's Unicode-normalizing Dictionary equality cannot lose keys.
public indirect enum CanonicalValue: Sendable, Codable {
    case string(String), boolean(Bool), null, array([CanonicalValue]), object([CanonicalMember])
    public static func decimal(_ value: Money) -> Self { .string(value.decimalString) }
    public static func integer(_ value: Int64) -> Self { .string(String(value)) }
    public func canonicalData() throws -> Data { Data(try rendered(depth: 0).utf8) }
    private func rendered(depth: Int) throws -> String {
        guard depth <= 64 else { throw SnapshotError.resourceLimit }
        switch self {
        case let .string(value): return Self.quoted(value)
        case let .boolean(value): return value ? "true" : "false"
        case .null: return "null"
        case let .array(values): return "[" + (try values.map { try $0.rendered(depth: depth + 1) }).joined(separator: ",") + "]"
        case let .object(members):
            guard Set(members.map { Array($0.key.utf16) }).count == members.count else { throw SnapshotError.duplicateProperty }
            let ordered = members.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
            return "{" + (try ordered.map { Self.quoted($0.key) + ":" + (try $0.value.rendered(depth: depth + 1)) }).joined(separator: ",") + "}"
        }
    }
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 0...31: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
public struct CanonicalMember: Sendable, Codable {
    public let key: String
    public let value: CanonicalValue
    public init(_ key: String, _ value: CanonicalValue) { self.key = key; self.value = value }
}
public struct ObjectIdentity: Sendable, Hashable, Codable {
    public let id: String, version: String
    public init(id: String, version: String) { self.id = id; self.version = version }
    public func validate() throws {
        guard identifier(id), identifier(version) else { throw SnapshotError.invalidIdentity }
    }
}
public struct ObjectReference: Sendable, Codable {
    public let role: String
    public let target: ObjectIdentity
    public let contentHash: String
    public init(role: String, target: ObjectIdentity, contentHash: String) {
        self.role = role; self.target = target; self.contentHash = contentHash
    }
    var canonical: CanonicalValue { .object([.init("role", .string(role)), .init("id", .string(target.id)),
                                            .init("version", .string(target.version)), .init("hash", .string(contentHash))]) }
}
public enum FrozenObjectKind: String, Sendable, Codable { case input, model, parameters, configuration, calendar, mapping, result }
public struct RetentionPermission: Sendable, Codable {
    public let mayStore: Bool, mayBackup: Bool
    public let evidenceReference: String
    public init(mayStore: Bool, mayBackup: Bool, evidenceReference: String) {
        self.mayStore = mayStore; self.mayBackup = mayBackup; self.evidenceReference = evidenceReference
    }
}
/// Immutable content includes ordered references; import address mappings live outside these bytes.
public struct FrozenObject: Sendable, Codable {
    public let identity: ObjectIdentity
    public let encodingVersion: String
    public let kind: FrozenObjectKind
    public let payload: CanonicalValue
    public let references: [ObjectReference]
    public let capturedAt: MillisecondInstant
    public let permission: RetentionPermission
    public let synthetic: Bool
    public init(identity: ObjectIdentity, kind: FrozenObjectKind, payload: CanonicalValue, references: [ObjectReference],
                capturedAt: MillisecondInstant, permission: RetentionPermission, synthetic: Bool) {
        self.identity = identity; self.encodingVersion = "snapshot-json.v1"; self.kind = kind; self.payload = payload
        self.references = references; self.capturedAt = capturedAt; self.permission = permission; self.synthetic = synthetic
    }
    public func contentBytes() throws -> Data {
        try validate()
        return try CanonicalValue.object([.init("encoding", .string(encodingVersion)), .init("kind", .string(kind.rawValue)),
            .init("payload", payload), .init("references", .array(references.map(\.canonical))), .init("capturedAt", .string(capturedAt.iso8601)),
            .init("mayStore", .boolean(permission.mayStore)), .init("mayBackup", .boolean(permission.mayBackup)),
            .init("permissionEvidence", .string(permission.evidenceReference)), .init("synthetic", .boolean(synthetic))]).canonicalData()
    }
    public func contentHash() throws -> String { digest(try contentBytes()) }
    public func validate() throws {
        try identity.validate()
        guard encodingVersion == "snapshot-json.v1" else { throw SnapshotError.unsupportedFormat }
        guard !permission.evidenceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SnapshotError.retentionDenied }
        var seen = Set<String>()
        for ref in references {
            try ref.target.validate()
            guard identifier(ref.role), hashString(ref.contentHash) else { throw SnapshotError.invalidIdentity }
            guard seen.insert(ref.role).inserted else { throw SnapshotError.duplicateObject }
        }
    }
}
public enum ProtectionKind: String, Sendable, Codable { case decisionVersion, ledger, analysisRun, researchRun, audit, exportManifest, restoring }
public struct SnapshotRoot: Sendable, Codable {
    public let identity: ObjectIdentity
    public let kind: ProtectionKind
    public let references: [ObjectReference]
    public init(identity: ObjectIdentity, kind: ProtectionKind, references: [ObjectReference]) {
        self.identity = identity; self.kind = kind; self.references = references
    }
    public func contentHash() throws -> String {
        digest(try CanonicalValue.object([.init("id", .string(identity.id)), .init("version", .string(identity.version)),
            .init("kind", .string(kind.rawValue)), .init("references", .array(references.map(\.canonical)))]).canonicalData())
    }
}
public struct SnapshotBundle: Sendable, Codable {
    public let schemaVersion: String
    public let sourceNamespace: UUID
    public let objects: [FrozenObject]
    public let roots: [SnapshotRoot]
    public init(sourceNamespace: UUID, objects: [FrozenObject], roots: [SnapshotRoot]) {
        self.schemaVersion = "snapshot-bundle.v1"; self.sourceNamespace = sourceNamespace; self.objects = objects; self.roots = roots
    }
    /// Checks every object, including unrooted cache entries. No compatible-version guessing.
    public func validate(forBackup: Bool = false) throws {
        guard schemaVersion == "snapshot-bundle.v1" else { throw SnapshotError.unsupportedFormat }
        guard objects.count <= 100_000, roots.count <= 100_000 else { throw SnapshotError.resourceLimit }
        guard Set(objects.map(\.identity)).count == objects.count, Set(roots.map(\.identity)).count == roots.count else { throw SnapshotError.duplicateObject }
        let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.identity, $0) })
        var counts: [ObjectIdentity: Int] = [:], dependents: [ObjectIdentity: [ObjectIdentity]] = [:]
        for object in objects {
            try object.validate()
            guard object.permission.mayStore, !forBackup || object.permission.mayBackup else { throw SnapshotError.retentionDenied }
            counts[object.identity] = object.references.count
            for ref in object.references {
                guard byID[ref.target] != nil else { throw SnapshotError.missingReference }
                dependents[ref.target, default: []].append(object.identity)
            }
        }
        // Kahn traversal, not recursion on an untrusted dependency chain.
        var ready = counts.filter { $0.value == 0 }.map(\.key), cursor = 0
        while cursor < ready.count {
            let id = ready[cursor]; cursor += 1
            for child in dependents[id, default: []] { counts[child]! -= 1; if counts[child] == 0 { ready.append(child) } }
        }
        guard ready.count == objects.count else { throw SnapshotError.cycle }
        let hashes = try Dictionary(uniqueKeysWithValues: objects.map { ($0.identity, try $0.contentHash()) })
        func check(_ refs: [ObjectReference]) throws {
            for ref in refs {
                guard identifier(ref.role), hashString(ref.contentHash) else { throw SnapshotError.invalidIdentity }
                guard let hash = hashes[ref.target] else { throw SnapshotError.missingReference }
                guard hash == ref.contentHash else { throw SnapshotError.hashMismatch }
            }
        }
        for object in objects { try check(object.references) }
        for root in roots {
            try root.identity.validate()
            guard !root.references.isEmpty, Set(root.references.map(\.role)).count == root.references.count else { throw SnapshotError.invalidIdentity }
            try check(root.references)
        }
    }
}
public func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func identifier(_ text: String) -> Bool { text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil }
func hashString(_ text: String) -> Bool { text.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil }
