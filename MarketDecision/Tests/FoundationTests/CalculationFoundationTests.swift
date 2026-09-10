import Foundation
import Testing
import CoreDomain
import DataContracts

// Synthetic identity model only. Approval metadata here is fixture input, not production approval.
let registryFixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
func sampleParameters(version: String = "1", state: DefinitionState = .approved,
                      values: [String: ParameterValue] = ["factor": .integer(1)]) -> ParameterSet {
    ParameterSet(id: "synthetic.parameters", version: version,
                 revisionID: version == "1" ? UUID(uuidString: "00000000-0000-0000-0000-000000000001")! : UUID(),
                 values: values, state: state, dispositionReference: "synthetic.disposition")
}
func sampleModel(parameters: ParameterSet, version: String = "1", state: DefinitionState = .approved,
                 policy: String = Money.numericPolicyVersion, deprecatedAt: Date? = nil,
                 inputs: [ModelInput] = [.init(name: "input", unit: "ratio", role: .required)]) -> ModelDefinition {
    ModelDefinition(id: "synthetic.identity", version: version,
                    revisionID: version == "1" ? UUID(uuidString: "00000000-0000-0000-0000-000000000002")! : UUID(),
                    owner: "synthetic.tests", purpose: "Identity metadata fixture", inputs: inputs,
                    outputs: [.init(name: "result", unit: "ratio")], formula: "output = input", formulaVersion: "identity.1",
                    implementationReference: "synthetic-only", defaultParameters: parameters.reference,
                    numericPolicyVersion: policy, state: state, dispositionReference: "synthetic.disposition",
                    knownLimitations: ["No financial model or provider qualification"], testFixtures: ["synthetic.identity"],
                    introducedAt: try! MillisecondInstant(rounding: registryFixtureDate), deprecatedAt: deprecatedAt.map { try! MillisecondInstant(rounding: $0) })
}
func resolvedSample() async throws -> ResolvedModel {
    let registry = ModelRegistry(), parameters = sampleParameters()
    let definition = sampleModel(parameters: parameters)
    try await registry.register(parameters); try await registry.register(definition)
    return try await registry.resolve(reference: definition.reference, at: registryFixtureDate)
}

@Suite struct DecimalFoundationTests {
    @Test func explicitScalesAndPresentationPreserveOriginal() throws {
        let value = try Money("12.345678905")
        #expect(try value.posted().decimalString == "12.35")
        #expect(try value.rounded(to: .unitPrice).decimalString == "12.345679")
        #expect(try value.rounded(to: .shares).decimalString == "12.3456789")
        #expect(try Money("-0.005").fixedString() == "0.00")
        #expect(try Money("1").fixedString(at: .unitPrice) == "1.000000")
        #expect(value.decimalString == "12.345678905")
    }
    @Test func exactArithmeticDoesNotPostIntermediateAmounts() throws {
        let value = try Money("0.005").adding(Money("0.005"))
        #expect(try value.posted() == Money("0.01"))
        #expect(try Money("10.01").subtracting(Money("11.02")) == Money("-1.01"))
        #expect(try Money("123.456789").multiplied(by: "0.125") == Money("15.432098625"))
        #expect(try Money("-0.1").multiplied(by: "-0.2") == Money("0.02"))
        #expect(try Money("-1") < Money("0"))
    }
    // Encodable arrays keep case IDs distinct on Swift Testing 6.1 as well as newer SDKs.
    @Test(arguments: [
        ("1", "3", "0.333333333333333333"), ("2", "3", "0.666666666666666667"),
        ("-2", "3", "-0.666666666666666667"), ("2", "-3", "-0.666666666666666667"),
        ("-2", "-3", "0.666666666666666667"), ("1.25", "0.5", "2.5"),
        ("0", "3", "0"), ("0.000000000000000001", "2", "0"),
        ("0.000000000000000003", "2", "0.000000000000000002"),
        ("-0.000000000000000003", "2", "-0.000000000000000002"),
        ("1.999999999999999999", "2", "1"),
        ("1.0000000000000000005", "1", "1"),
        ("1.0000000000000000005000000000000000001", "1", "1.000000000000000001"),
        ("1.0000000000000000004999999999999999999", "1", "1"),
        ("99999999999999999999.999999999999999999", "1", "99999999999999999999.999999999999999999")
    ].map { [$0.0, $0.1, $0.2] })
    func exactDivision(_ vector: [String]) throws {
        try #require(vector.count == 3, "A division fixture requires dividend, divisor and expected result")
        #expect(try Money(vector[0]).divided(by: vector[1]) == Money(vector[2]))
    }
    @Test func decimalInputNeverSilentlyUnderflowsOrAcceptsPartialText() throws {
        for text in ["0." + String(repeating: "0", count: 200) + "1", "1\n", " 1", "+1", "1,25", "١", "1e-10"] {
            #expect(throws: MoneyError.invalidDecimal) { try Money(text) }
        }
        let smallest = "0." + String(repeating: "0", count: 127) + "1"
        #expect(try Money(smallest).decimalString == smallest)
        #expect(try Money("1." + String(repeating: "0", count: 80)).decimalString == "1")
        #expect(try Money("-0.000").decimalString == "0")
    }
    @Test func arithmeticRejectsLossOverflowAndZeroDivisor() throws {
        #expect(throws: MoneyError.divisionByZero) { try Money("1").divided(by: "-0.00") }
        #expect(throws: (any Error).self) { try Money("99999999999999999999999999999999999999").adding(Money("0.1")) }
        #expect(throws: (any Error).self) { try Money("99999999999999999999999999999999999999").multiplied(by: "9") }
        #expect(throws: (any Error).self) { try Money("1" + String(repeating: "0", count: 127)).multiplied(by: "1" + String(repeating: "0", count: 127)) }
        #expect(throws: MoneyError.precisionExceeded) { try Money("99999999999999999999999999999999999999").divided(by: "3.1") }
    }
    @Test func allocationConservesPostedTotalForEverySignAndOrder() throws {
        for text in ["10.005", "-10.005", "10.015", "-10.015", "0", "0.01", "-0.01", "1234567890.01"] {
            let money = try Money(text)
            for count in 1...13 {
                let ids = (0..<count).map { String(format: "lot%02d", $0) }
                let a = try money.allocatedEqually(to: ids), b = try money.allocatedEqually(to: ids.reversed())
                #expect(a == b)
                #expect(try a.values.reduce(Money("0")) { try $0.adding($1) } == money.posted())
                #expect(try a.values.allSatisfy { try $0 == $0.posted() })
            }
        }
        #expect(try Money("10.015").allocatedEqually(to: ["c", "a", "b"]) == ["a": Money("3.34"), "b": Money("3.34"), "c": Money("3.34")])
        #expect(try Money("-10.01").allocatedEqually(to: ["c", "a", "b"]) == ["a": Money("-3.33"), "b": Money("-3.33"), "c": Money("-3.35")])
        for ids: [String] in [[], ["a", "a"], [" "], ["\n"]] {
            #expect(throws: MoneyError.invalidLots) { try Money("1").allocatedEqually(to: ids) }
        }
    }
    @Test func serializedDecimalsAreCanonicalAndNumericJSONIsRejected() throws {
        let encoded = try JSONEncoder().encode(Money("1.2300"))
        #expect(String(decoding: encoded, as: UTF8.self) == "\"1.23\"")
        #expect(try JSONDecoder().decode(Money.self, from: encoded).decimalString == "1.23")
        for json in ["null", "1.23", "\"NaN\"", "\"1e3\"", "\"01\""] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Money.self, from: Data(json.utf8)) }
        }
    }
}

@Suite struct ModelFoundationTests {
    @Test func registrationPinsAllContentAndRejectsBothKindsOfOverwrite() async throws {
        let registry = ModelRegistry(), parameters = sampleParameters(), model = sampleModel(parameters: sampleParameters())
        await #expect(throws: RegistryError.unknownVersion) { try await registry.register(model) }
        try await registry.register(parameters); try await registry.register(model)
        await #expect(throws: RegistryError.duplicateVersion) { try await registry.register(parameters) }
        await #expect(throws: RegistryError.duplicateVersion) { try await registry.register(sampleParameters(values: ["factor": .integer(2)])) }
        await #expect(throws: RegistryError.duplicateVersion) { try await registry.register(model) }
        let bound = try await registry.resolve(reference: model.reference, at: registryFixtureDate)
        #expect(bound.parameters == parameters && bound.definition == model)
        let wrong = RegistryReference(id: model.id, version: model.version, revisionID: model.revisionID, contentHash: String(repeating: "0", count: 64), fingerprintVersion: model.reference.fingerprintVersion)
        await #expect(throws: RegistryError.referenceMismatch) { try await registry.resolve(reference: wrong, at: registryFixtureDate) }
        await #expect(throws: RegistryError.unknownVersion) { try await registry.definition(id: model.id, version: "latest") }
    }
    @Test func decodedNewVersionCannotReuseAnExistingRevisionIdentity() async throws {
        let registry = ModelRegistry(), parameters = sampleParameters(), model = sampleModel(parameters: sampleParameters())
        try await registry.register(parameters); try await registry.register(model)
        var modelObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        modelObject["version"] = "2"
        let reusedModel = try JSONDecoder().decode(ModelDefinition.self, from: JSONSerialization.data(withJSONObject: modelObject))
        await #expect(throws: RegistryError.duplicateRevision) { try await registry.register(reusedModel) }
        var parameterObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any])
        parameterObject["version"] = "2"
        let reusedParameters = try JSONDecoder().decode(ParameterSet.self, from: JSONSerialization.data(withJSONObject: parameterObject))
        await #expect(throws: RegistryError.duplicateRevision) { try await registry.register(reusedParameters) }
    }
    @Test func sameParameterLabelWithDifferentBytesCannotBind() async throws {
        let registry = ModelRegistry(), parameters = sampleParameters()
        try await registry.register(parameters)
        let substituted = sampleParameters(values: ["factor": .integer(99)])
        await #expect(throws: RegistryError.referenceMismatch) { try await registry.register(sampleModel(parameters: substituted)) }
        #expect(parameters.reference != substituted.reference)
    }
    @Test func draftsAndMissingParametersNeverBecomeCalculable() async throws {
        for state: DefinitionState in [.draft, .blockedBySpec] {
            let registry = ModelRegistry(), parameters = sampleParameters(state: state)
            let model = sampleModel(parameters: parameters)
            try await registry.register(parameters); try await registry.register(model)
            await #expect(throws: RegistryError.unapproved) { try await registry.resolve(reference: model.reference, at: registryFixtureDate) }
            let second = sampleModel(parameters: parameters, version: "draft", state: state)
            try await registry.register(second)
            #expect(try await registry.definition(id: second.id, version: second.version) == second)
        }
        let missing = sampleParameters(values: ["factor": .unspecified(specReference: "synthetic.unresolved")])
        #expect(throws: RegistryError.invalidDefinition) { try missing.validate() }
        try sampleParameters(state: .blockedBySpec, values: ["factor": .unspecified(specReference: "synthetic.unresolved")]).validate()
    }
    @Test func lifecycleAndNumericPolicyAreCheckedAtEveryCalculation() async throws {
        let registry = ModelRegistry(), parameters = sampleParameters()
        let expiry = registryFixtureDate.addingTimeInterval(10), model = sampleModel(parameters: parameters, deprecatedAt: registryFixtureDate.addingTimeInterval(10))
        try await registry.register(parameters); try await registry.register(model)
        let bound = try await registry.resolve(reference: model.reference, at: registryFixtureDate)
        #expect(throws: RegistryError.inactiveModel) { try bound.validateForCalculation(at: expiry) }
        await #expect(throws: RegistryError.inactiveModel) { try await registry.resolve(reference: model.reference, at: registryFixtureDate.addingTimeInterval(-1)) }
        #expect(try await registry.definition(id: model.id, version: model.version) == model)
        let unknown = sampleModel(parameters: parameters, version: "future", policy: "unknown.policy")
        try await registry.register(unknown)
        await #expect(throws: RegistryError.unsupportedNumericPolicy) { try await registry.resolve(reference: unknown.reference, at: registryFixtureDate) }
    }
    @Test func dependencyRolesRejectMissingUnknownAndDuplicateSingletons() async throws {
        let registry = ModelRegistry(), parameters = sampleParameters()
        let model = sampleModel(parameters: parameters, inputs: [
            .init(name: "price", unit: "ratio", role: .required),
            .init(name: "history", unit: "ratio", role: .required, allowsMultiple: true),
            .init(name: "optional", unit: "ratio", role: .optional),
            .init(name: "comparison", unit: "ratio", role: .comparison)])
        try await registry.register(parameters); try await registry.register(model)
        let bound = try await registry.resolve(reference: model.reference, at: registryFixtureDate)
        try bound.validateInputs(["price", "history", "history"])
        for roles in [[], ["price"], ["price", "history", "unknown"], ["price", "price", "history"]] {
            #expect(throws: RegistryError.invalidInputs) { try bound.validateInputs(roles) }
        }
    }
    @Test func roundTripKeepsCompleteDefinitionAndDeterministicFingerprint() async throws {
        let first = sampleParameters(values: ["a": .decimal(try Money("1.00")), "b": .boolean(true)])
        let second = sampleParameters(values: ["b": .boolean(true), "a": .decimal(try Money("1"))])
        #expect(first.reference == second.reference)
        let model = sampleModel(parameters: first)
        let decoded = try JSONDecoder().decode(ModelDefinition.self, from: JSONEncoder().encode(model))
        #expect(decoded == model && decoded.reference == model.reference)
        #expect(try JSONDecoder().decode(ParameterSet.self, from: JSONEncoder().encode(first)) == first)
        let registry = ModelRegistry(); try await registry.register(first); try await registry.register(decoded)
    }
    @Test func newVersionsNeverRewritePreviouslyResolvedContent() async throws {
        let registry = ModelRegistry(), original = sampleParameters()
        let first = sampleModel(parameters: original)
        try await registry.register(original); try await registry.register(first)
        let old = try await registry.resolve(reference: first.reference, at: registryFixtureDate)
        let next = sampleParameters(version: "2", values: ["factor": .integer(2)])
        let second = sampleModel(parameters: next, version: "2")
        try await registry.register(next); try await registry.register(second)
        #expect(old.parameters.values["factor"] == .integer(1))
        #expect(try await registry.resolve(reference: first.reference, at: registryFixtureDate).parameters == original)
        #expect(try await registry.resolve(reference: second.reference, at: registryFixtureDate).parameters == next)
        #expect(old.definition.reference != second.reference)
    }
    @Test func unapprovedModelWithApprovedParametersIsStillBlocked() async throws {
        let registry = ModelRegistry(), parameters = sampleParameters()
        let model = sampleModel(parameters: parameters, state: .draft)
        try await registry.register(parameters); try await registry.register(model)
        await #expect(throws: RegistryError.unapproved) { try await registry.resolve(reference: model.reference, at: registryFixtureDate) }
    }
    @Test func malformedDecodedDefinitionsStillFailAtRegistration() async throws {
        let params = sampleParameters(), model = sampleModel(parameters: sampleParameters())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        object["owner"] = " "
        let decoded = try JSONDecoder().decode(ModelDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        let registry = ModelRegistry(); try await registry.register(params)
        await #expect(throws: RegistryError.invalidDefinition) { try await registry.register(decoded) }
        #expect(throws: RegistryError.invalidDefinition) { try sampleModel(parameters: params, deprecatedAt: registryFixtureDate).validate() }
        #expect(throws: RegistryError.invalidDefinition) { try sampleModel(parameters: params, inputs: [.init(name: "same", unit: "ratio", role: .required), .init(name: "same", unit: "ratio", role: .optional)]).validate() }
    }
}

@Suite struct DecimalIndependentReferenceTests {
    // Independently calculated with Python Decimal precision 160, half-even at 18 places.
    // New synthetic vectors; not the private acceptance corpus or financial model validation.
    @Test func arithmeticMatchesIndependentReferenceVectors() throws {
        let vectors: [(String, String, String, String)] = [
            ("add", "49832307.7", "792737", "50625044.7"),
            ("subtract", "49832307.7", "792737", "49039570.7"),
            ("multiply", "49832307.7", "792737", "39503914109174.9"),
            ("divide", "49832307.7", "792737", "62.861084697699236947"),
            ("add", "-7137.40388", "0.040768", "-7137.363112"),
            ("subtract", "-7137.40388", "0.040768", "-7137.444648"),
            ("multiply", "-7137.40388", "0.040768", "-290.97768137984"),
            ("divide", "-7137.40388", "0.040768", "-175073.682299843014128728"),
            ("add", "6964004.15", "52472.6", "7016476.75"),
            ("subtract", "6964004.15", "52472.6", "6911531.55"),
            ("multiply", "6964004.15", "52472.6", "365419404161.290"),
            ("divide", "6964004.15", "52472.6", "132.716963710584190606"),
            ("add", "-9713222.94", "130.222", "-9713092.718"),
            ("subtract", "-9713222.94", "130.222", "-9713353.162"),
            ("multiply", "-9713222.94", "130.222", "-1264875317.69268"),
            ("divide", "-9713222.94", "130.222", "-74589.723241848535577706"),
            ("add", "-87.0826621", "900.467", "813.3843379"),
            ("subtract", "-87.0826621", "900.467", "-987.5496621"),
            ("multiply", "-87.0826621", "900.467", "-78415.0634932007"),
            ("divide", "-87.0826621", "900.467", "-0.096708332565213384"),
            ("add", "52507.4047", "60.5200", "52567.9247"),
            ("subtract", "52507.4047", "60.5200", "52446.8847"),
            ("multiply", "52507.4047", "60.5200", "3177748.13244400"),
            ("divide", "52507.4047", "60.5200", "867.604175479180436219"),
            ("add", "81468745.0", "953171", "82421916.0"),
            ("subtract", "81468745.0", "953171", "80515574.0"),
            ("multiply", "81468745.0", "953171", "77653645140395.0"),
            ("divide", "81468745.0", "953171", "85.471279550049256639"),
            ("add", "-124085.217", "105.816", "-123979.401"),
            ("subtract", "-124085.217", "105.816", "-124191.033"),
            ("multiply", "-124085.217", "105.816", "-13130201.322072"),
            ("divide", "-124085.217", "105.816", "-1172.650799501020639601"),
            ("add", "-880472061", "57.2666", "-880472003.7334"),
            ("subtract", "-880472061", "57.2666", "-880472118.2666"),
            ("multiply", "-880472061", "57.2666", "-50421641328.4626"),
            ("divide", "-880472061", "57.2666", "-15374966.577376690776124303"),
            ("add", "-39670.1770", "7215.0", "-32455.1770"),
            ("subtract", "-39670.1770", "7215.0", "-46885.1770"),
            ("multiply", "-39670.1770", "7215.0", "-286220327.05500"),
            ("divide", "-39670.1770", "7215.0", "-5.498292030492030492"),
            ("add", "468284811", "1494.65", "468286305.65"),
            ("subtract", "468284811", "1494.65", "468283316.35"),
            ("multiply", "468284811", "1494.65", "699921892761.15"),
            ("divide", "468284811", "1494.65", "313307.336834710467333489"),
            ("add", "-980879.972", "1857.48", "-979022.492"),
            ("subtract", "-980879.972", "1857.48", "-982737.452"),
            ("multiply", "-980879.972", "1857.48", "-1821964930.39056"),
            ("divide", "-980879.972", "1857.48", "-528.070273704158322028")
        ]
        for (operation, lhs, rhs, expected) in vectors {
            let value = try Money(lhs), result: Money
            switch operation {
            case "add": result = try value.adding(Money(rhs))
            case "subtract": result = try value.subtracting(Money(rhs))
            case "multiply": result = try value.multiplied(by: rhs)
            default: result = try value.divided(by: rhs)
            }
            #expect(try result == Money(expected))
        }
    }
}
