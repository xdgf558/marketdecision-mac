import Foundation
import CoreDomain

// Test-only executable, not linked into the app. No disk, network or Keychain access.
// Independently decodes/encodes the complete synthetic model bundle between processes.
struct Fixture: Codable { let parameters: ParameterSet; let model: ModelDefinition; let reference: RegistryReference }
@main struct FoundationCodecProbe {
    static func main() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let registry = ModelRegistry()
        try await registry.register(fixture.parameters); try await registry.register(fixture.model)
        _ = try await registry.resolve(reference: fixture.reference, at: fixture.model.introducedAt.date)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(fixture))
    }
}
