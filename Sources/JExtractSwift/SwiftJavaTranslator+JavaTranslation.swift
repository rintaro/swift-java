//
//  SwiftJavaTranslator+JavaTranslation.swift
//  SwiftJava
//
//  Created by Rintaro Ishizaki on 5/25/25.
//

extension Swift2JavaTranslator {
  func translate(
    swiftSignature: SwiftFunctionSignature,
    as apiKind: SwiftAPIKind
  ) throws -> TranslatedFunctionSignature {
    let lowering = CdeclLowering(swiftStdlibTypes: self.swiftStdlibTypes)
    let loweredSignature = try lowering.lowerFunctionSignature(swiftSignature, apiKind: apiKind)

    let translation = JavaTranslation(swiftStdlibTypes: self.swiftStdlibTypes)
    let translated = try translation.translate(loweredFunctionSignature: loweredSignature)

    return translated
  }
}

struct JavaThunkPrinter {
  var printer: CodePrinter

  mutating func render(
    forFunction functionSignature: TranslatedFunctionSignature,
    name: String
  ) throws {
    try printer.printTypeDecl("private final class \(name)") { printer in
      printer.print("static FunctionDescriptor DESC = ", .continue);
      try printFunctionDescriptorValue(&printer, forFunction: functionSignature.loweredSignature)
    }
  }

  func printFunctionDescriptorValue(
    _ printer: inout CodePrinter,
    forFunction loweredSignature: LoweredFunctionSignature,
  ) throws {
    let resultType = try CType(cdeclType: loweredSignature.result.cdeclResultType)
    let loweredParams = loweredSignature.allLoweredParameters
    let isEmptyParam = loweredParams.isEmpty

    if resultType.isVoid {

    }
  }
}


import JavaTypes

/// Represent a parameter in Java code.
struct JavaParameter {
  /// The type.
  var javaType: JavaType

  /// The name.
  var parameterName: String
}

enum JavaModifier {
  // Access modifiers
  case `public`
  case `private`
  case `protected`

  // Non-access modifiers.
  case `final`
  case `static`
  case `abstract`
  case `transient`
  case `synchronized`
  case `volatile`
}

struct JavaMethodSignature {
  var modifiers: [JavaModifier]
  var returnType: JavaType
  var parameters: [JavaParameter]
}

struct TranslatedParameter {
  var javaParameters: [JavaParameter]
  var conversion: JavaConversionStep
}

struct TranslatedResult {
  var javaResultType: JavaType
  var conversion: JavaConversionStep
}

struct TranslatedFunctionSignature {
  var loweredSignature: LoweredFunctionSignature

  ///
  var selfParameter: TranslatedParameter?
  var parameters: [TranslatedParameter]
  var result: TranslatedResult
}

extension TranslatedFunctionSignature {
  /// Whether if the down-calling requires "Arena" or not.
  ///
  /// This is true if the result is returned indirectly.
  var requiresArena: Bool {
    return loweredSignature.result.hasIndirectResult
  }
}

struct JavaTranslation {
  var swiftStdlibTypes: SwiftStandardLibraryTypes

  func translate(
    loweredFunctionSignature: LoweredFunctionSignature
  ) throws -> TranslatedFunctionSignature {

    // 'self'
    let selfParameter: TranslatedParameter?
    if let loweredSelf = loweredFunctionSignature.selfParameter {
      guard case .instance(let swiftSelf) = loweredFunctionSignature.original.selfParameter! else {
        fatalError("unreachable")
      }
      selfParameter = try self.translate(loweredParam: loweredSelf, swiftParam: swiftSelf)
    } else {
      selfParameter = nil
    }

    // Regular parameters.
    let parameters: [TranslatedParameter] = try loweredFunctionSignature.parameters.enumerated()
      .map { (idx, loweredParam) in
        let swiftParam = loweredFunctionSignature.original.parameters[idx]
        return try self.translate(loweredParam: loweredParam, swiftParam: swiftParam)
      }

    // Result.
    var result = try self.translate(
      loweredResult: loweredFunctionSignature.result,
      swiftResult: loweredFunctionSignature.original.result
    )

    return TranslatedFunctionSignature(
      loweredSignature: loweredFunctionSignature,
      selfParameter: selfParameter,
      parameters: parameters,
      result: result
    )
  }

  func translate(
    loweredParam: LoweredParameter,
    swiftParam: SwiftParameter
  ) throws -> TranslatedParameter {
    // If there is a 1:1 mapping between this Swift type and a C type.z
    if let cType = try? CType(cdeclType: swiftParam.type) {
      if let javaType = JavaType(cType: cType) {
        return TranslatedParameter(
          javaParameters: [
            JavaParameter(
              javaType: javaType,
              parameterName: loweredParam.cdeclParameters[0].parameterName!
            )
          ],
          conversion: .identity
        )
      }
    }
    let swiftType = swiftParam.type

    switch swiftType {
    case .metatype(let swiftType):
      // Metatype are expressed as 'org.swift.swiftkit.SwiftAnyType'
      return TranslatedParameter(
        javaParameters: [
          JavaParameter(
            javaType: JavaType.class(package: "org.swift.swiftkit", name: "SwiftAnyType"),
            parameterName: loweredParam.cdeclParameters[0].parameterName!)
        ],
        conversion: .swiftValueSelfSegment
      )

    case .nominal(let swiftNominalType):
      if let knownType = swiftNominalType.nominalTypeDecl.knownStandardLibraryType {
        if swiftParam.convention == .inout {
          // FIXME: Support non-trivial 'inout' for builtin types.
          throw JavaTranslationError.inoutNotSupported(swiftType)
        }
        switch knownType {
        case .unsafePointer, .unsafeMutablePointer:
          // FIXME: Implement
          throw JavaTranslationError.unhandledType(swiftType)
        case .unsafeBufferPointer, .unsafeMutableBufferPointer:
          // FIXME: Implement
          throw JavaTranslationError.unhandledType(swiftType)

        case .string:
          return TranslatedParameter(
            javaParameters: [
              JavaParameter(
                javaType: .javaLangString,
                parameterName: loweredParam.cdeclParameters[0].parameterName!
              )
            ],
            conversion: .swiftkitBuiltin
          )

        default:
          throw JavaTranslationError.unhandledType(swiftType)
        }
      }

      // Generic types are not supported yet.
      guard swiftNominalType.genericArguments == nil else {
        throw JavaTranslationError.unhandledType(swiftType)
      }

      return TranslatedParameter(
        javaParameters: [
          JavaParameter(
            javaType: try translate(swiftType: swiftType),
            parameterName: loweredParam.cdeclParameters[0].parameterName!
          )
        ],
        conversion: .swiftValueSelfSegment
      )

    case .tuple(let elements):
      // TODO: Implement.
      throw JavaTranslationError.unhandledType(swiftType)

    case .function(let fn) where fn.parameters.isEmpty && fn.resultType.isVoid:
      return TranslatedParameter(
        javaParameters: [
          JavaParameter(
            javaType: JavaType.class(package: "java.lang", name: "Runnable"),
            parameterName: loweredParam.cdeclParameters[0].parameterName!)
        ],
        conversion: .upcallStub
      )

    case .optional, .function:
      throw JavaTranslationError.unhandledType(swiftType)
    }
  }

  func translate(
    loweredResult: LoweredResult,
    swiftResult: SwiftResult
  ) throws -> TranslatedResult {
    // If there is a 1:1 mapping between this Swift type and a C type.z
    if let cType = try? CType(cdeclType: swiftResult.type) {
      if let javaType = JavaType(cType: cType) {
        return TranslatedResult(
          javaResultType: javaType,
          conversion: .identity
        )
      }
    }

    let swiftType = swiftResult.type
    switch swiftType {
    case .metatype(let swiftType):
      // Metatype are expressed as 'org.swift.swiftkit.SwiftAnyType'
      return TranslatedResult(
        javaResultType: JavaType.class(package: "org.swift.swiftkit", name: "SwiftAnyType"),
        conversion: .call("SwiftAnyType")
      )

    case .nominal(let swiftNominalType):
      if let knownType = swiftNominalType.nominalTypeDecl.knownStandardLibraryType {
        switch knownType {
        case .unsafePointer, .unsafeMutablePointer:
          // FIXME: Implement
          throw JavaTranslationError.unhandledType(swiftType)
        case .unsafeBufferPointer, .unsafeMutableBufferPointer:
          // FIXME: Implement
          throw JavaTranslationError.unhandledType(swiftType)
        case .string:
          // FIXME: Implement
          throw JavaTranslationError.unhandledType(swiftType)
        default:
          throw JavaTranslationError.unhandledType(swiftType)
        }
      }

      // Generic types are not supported yet.
      guard swiftNominalType.genericArguments == nil else {
        throw JavaTranslationError.unhandledType(swiftType)
      }

      return TranslatedResult(
        javaResultType: .class(package: nil, name: swiftNominalType.nominalTypeDecl.name),
        // Don't convert the memory segment to S
        conversion:  .construct(swiftNominalType.nominalTypeDecl.name)
      )

      return translate(loweredResult: <#T##LoweredResult#>, swiftResult: <#T##SwiftResult#>)(
        javaParameters: [
          JavaParameter(
            javaType: try translate(swiftType: swiftType),
            parameterName: loweredParam.cdeclParameters[0].parameterName!
          )
        ],
        conversion: .swiftValueSelfSegment
      )

    case .tuple(let elements):
      // TODO: Implement.
      throw JavaTranslationError.unhandledType(swiftType)

    case .function(let fn) where fn.parameters.isEmpty && fn.resultType.isVoid:
      return TranslatedParameter(
        javaParameters: [
          JavaParameter(
            javaType: JavaType.class(package: "java.lang", name: "Runnable"),
            parameterName: loweredParam.cdeclParameters[0].parameterName!)
        ],
        conversion: .upcallStub
      )

    case .optional, .function:
      throw JavaTranslationError.unhandledType(swiftType)
    }

  }

  func translate(
    swiftType: SwiftType
  ) throws -> JavaType {
    JavaType.class(package: nil, name: "")
  }
}

protocol JavaLoweringGenerator {
  var requiresArena: Bool { get }
  func prepareParameter() -> String
  func fixupResult() -> String
}

enum JavaConversionStep {

  // Pass through.
  case pass

  // 'value.$memorySegment()'
  case swiftValueSelfSegment

  // Create a memory segment for indirect returning value.
  case newMemorySegment(layout: String)

  // Make an upcall stub for a callbacks.
  case upcallStub

  // `SwiftKit` should have a special method to lower the parameter.
  case swiftkitBuiltin

  // Temporarily stores the `step` in a variable, and explodes its components to
  // a list of comma separated values.
  indirect case explode(step: JavaConversionStep, tempName: String, fields: [String])

  case construct(javaType: JavaType)

  var requiresArena: Bool {
    switch self {
    case .identity, .swiftValueSelfSegment, .construct(javaType: <#T##JavaType#>):
      false
    case .newMemorySegment, .swiftkitBuiltin, .upcallStub:
      true
    case .explode(let step, _, _):
      step.requiresArena
    }
  }

  func printBefore(printer: inout CodePrinter, placeholder: String) {
    switch self {
    case .identity:
      printer.print(placeholder, .continue)

    case .swiftValueSelfSegment:
      printer.print(placeholder, .continue)
      printer.print(".$memorySegment()", .continue)

    case .
    }

    switch self {
    case .identity:
      return ([], placeholder)
    case .swiftValueSelfSegment:
      return ([], "\(placeholder).$memorySegment()")
    case .newMemorySegment(let layout):
      return (
        statements: ["$\(placeholder)_segment = arena.allocate(\(layout))"],
        result: "$\(placeholder)_segment"
      )
    case .swiftkitBuiltin:
      return ([], "SwiftKit.lowerParameter(\(placeholder))")

    case .explode(let inner, let tempName, let components):
      return (
        statements: [
          "var $\(tempName) = \(placeholder)"
        ],
        result: components.map({ "$\(tempName).\($0)" }).joined(separator: ", ")
      )

    case .upcallStub:
      // TODO: Implement
      return (
        statements: [
          """
          $\(placeholder) = func = Linker.nativeLinker().upcallStub(
              \(placeholder), FunctionDescriptor.ofVoid(), arena
          )
          """
        ],
        result: "$\(placeholder)"
      )

    case .constructSwiftValue(let type):
      return ([
        """
        arena.allocate(\(type).$layout())
        """
      ], "new \(type)(\(placeholder))")
    }
  }
}

extension JavaType {
  init?(cType: CType) {
    switch cType {
    case .integral(.bool): self = .boolean
    case .integral(.signed(bits: 8)): self = .byte
    case .integral(.signed(bits: 16)): self = .short
    case .integral(.signed(bits: 32)): self = .int
    case .integral(.unsigned(bits: 16)): self = .char
    case .floating(.float): self = .float
    case .floating(.double): self = .double
    case .void: self = .void
    default: return nil
    }
  }

}

enum JavaTranslationError: Error {
  case inoutNotSupported(SwiftType)
  case unhandledType(SwiftType)
}
