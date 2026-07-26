import Foundation
import FoundationModels

/// Translates the app's JSON-Schema subset (the `JSONValue` literals in
/// OllamaModels.swift) into FoundationModels generation schemas at runtime.
/// Deliberately avoids the `@Generable` macro so the CLT fallback toolchain
/// (no macro plugins) keeps building the project.
///
/// Supported keys: `type` (object/array/string/integer/number/boolean),
/// `properties`, `required`, `items`, `minItems`/`maxItems`, `enum` (strings),
/// `description`.
@available(macOS 26.0, *)
enum JSONSchemaTranslator {
    struct UnsupportedSchema: Error {
        let detail: String
    }

    static func generationSchema(from schema: JSONValue, rootName: String = "Output")
        throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(from: schema, name: rootName), dependencies: [])
    }

    static func dynamicSchema(from value: JSONValue, name: String)
        throws -> DynamicGenerationSchema {
        guard case .object(let schema) = value else {
            throw UnsupportedSchema(detail: "schema node is not an object: \(name)")
        }
        let description = stringValue(schema["description"])

        if case .array(let choices)? = schema["enum"] {
            return DynamicGenerationSchema(
                name: name, description: description,
                anyOf: choices.compactMap(stringValue))
        }

        switch stringValue(schema["type"]) {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = schema["items"] else {
                throw UnsupportedSchema(detail: "array without items: \(name)")
            }
            return DynamicGenerationSchema(
                arrayOf: try dynamicSchema(from: items, name: name + "Item"),
                minimumElements: intValue(schema["minItems"]),
                maximumElements: intValue(schema["maxItems"]))
        case "object", nil:
            guard case .object(let props)? = schema["properties"] else {
                return DynamicGenerationSchema(
                    name: name, description: description, properties: [])
            }
            var required: [String] = []
            if case .array(let list)? = schema["required"] {
                required = list.compactMap(stringValue)
            }
            // JSONValue.object is a dictionary, so the authored key order is
            // lost — but the `required` array IS ordered and lists every
            // property in all our schemas. Use it as the generation order
            // (fields are generated in schema order), then append any
            // optional properties alphabetically for determinism.
            let ordered = required.filter { props.keys.contains($0) }
                + props.keys.filter { !required.contains($0) }.sorted()
            let properties = try ordered.map { key in
                DynamicGenerationSchema.Property(
                    name: key,
                    schema: try dynamicSchema(
                        from: props[key]!,
                        name: name + key.prefix(1).uppercased() + String(key.dropFirst())),
                    isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(
                name: name, description: description, properties: properties)
        case .some(let other):
            throw UnsupportedSchema(detail: "unsupported type \(other) in \(name)")
        }
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value { string } else { nil }
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        if case .int(let int)? = value { int } else { nil }
    }
}
