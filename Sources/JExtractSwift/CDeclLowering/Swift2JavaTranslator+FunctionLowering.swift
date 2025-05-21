//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift.org project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift.org project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import JavaTypes
import SwiftSyntax

extension Swift2JavaTranslator {
  /// Lower the given function declaration to a C-compatible entrypoint,
  /// providing all of the mappings between the parameter and result types
  /// of the original function and its `@_cdecl` counterpart.
  @_spi(Testing)
  public func lowerFunctionSignature(
    _ decl: FunctionDeclSyntax,
    enclosingType: TypeSyntax? = nil
  ) throws -> LoweredFunctionSignature {
    let signature = try SwiftFunctionSignature(
      decl,
      enclosingType: try enclosingType.map { try SwiftType($0, symbolTable: symbolTable) },
      symbolTable: symbolTable
    )

    return try lowerFunctionSignature(signature)
  }

  /// Lower the given initializer to a C-compatible entrypoint,
  /// providing all of the mappings between the parameter and result types
  /// of the original function and its `@_cdecl` counterpart.
  @_spi(Testing)
  public func lowerFunctionSignature(
    _ decl: InitializerDeclSyntax,
    enclosingType: TypeSyntax? = nil
  ) throws -> LoweredFunctionSignature {
    let signature = try SwiftFunctionSignature(
      decl,
      enclosingType: try enclosingType.map { try SwiftType($0, symbolTable: symbolTable) },
      symbolTable: symbolTable
    )

    return try lowerFunctionSignature(signature)
  }

  /// Lower the given Swift function signature to a Swift @_cdecl function signature,
  /// which is C compatible, and the corresponding Java method signature.
  ///
  /// Throws an error if this function cannot be lowered for any reason.
  func lowerFunctionSignature(
    _ signature: SwiftFunctionSignature
  ) throws -> LoweredFunctionSignature {
    // Lower all of the parameters.
    let loweredParameters = try signature.parameters.enumerated().map { (index, param) in
      try lowerParameter(
        param.type,
        convention: param.convention,
        parameterName: param.parameterName ?? "_\(index)"
      )
    }

    // Lower the result.
    var loweredResult = try lowerParameter(
      signature.result.type,
      convention: .byValue,
      parameterName: "_result"
    )

    // If the result type doesn't lower to either empty (void) or a single
    // result, make it indirect.
    let indirectResult: Bool
    if loweredResult.cdeclParameters.count == 0 {
      // void result type
      indirectResult = false
    } else if loweredResult.cdeclParameters.count == 1,
              loweredResult.cdeclParameters[0].canBeDirectReturn {
      // Primitive result type
      indirectResult = false
    } else {
      loweredResult = try lowerParameter(
        signature.result.type,
        convention: .inout,
        parameterName: "_result"
      )
      indirectResult = true
    }

    // Lower the self parameter.
    let loweredSelf = try signature.selfParameter.flatMap { selfParameter in
      switch selfParameter {
      case .instance(let selfParameter):
        try lowerParameter(
          selfParameter.type,
          convention: selfParameter.convention,
          parameterName: selfParameter.parameterName ?? "self"
        )
      case .initializer, .staticMethod:
        nil
      }
    }

    // Collect all of the lowered parameters for the @_cdecl function.
    var allLoweredParameters: [LoweredParameters] = []
    var cdeclLoweredParameters: [SwiftParameter] = []
    allLoweredParameters.append(contentsOf: loweredParameters)
    cdeclLoweredParameters.append(
      contentsOf: loweredParameters.flatMap { $0.cdeclParameters }
    )

    // Lower self.
    if let loweredSelf {
      allLoweredParameters.append(loweredSelf)
      cdeclLoweredParameters.append(contentsOf: loweredSelf.cdeclParameters)
    }

    // Lower indirect results.
    let cdeclResult: SwiftResult
    if indirectResult {
      cdeclLoweredParameters.append(
        contentsOf: loweredResult.cdeclParameters
      )
      cdeclResult = .init(convention: .direct, type: .void)
    } else if loweredResult.cdeclParameters.count == 1,
              let primitiveResult = loweredResult.cdeclParameters.first {
      cdeclResult = .init(convention: .direct, type: primitiveResult.type)
    } else if loweredResult.cdeclParameters.count == 0 {
      cdeclResult = .init(convention: .direct, type: .void)
    } else {
      fatalError("Improper lowering of result for \(signature)")
    }

    let cdeclSignature = SwiftFunctionSignature(
      selfParameter: nil,
      parameters: cdeclLoweredParameters,
      result: cdeclResult
    )

    return LoweredFunctionSignature(
      original: signature,
      cdecl: cdeclSignature,
      parameters: allLoweredParameters,
      result: loweredResult
    )
  }

  func lowerParameter(
    _ type: SwiftType,
    convention: SwiftParameterConvention,
    parameterName: String
  ) throws -> LoweredParameters {
    // If there is a 1:1 mapping between this Swift type and a C type, we just
    // need to add the corresponding C parameter.
    if let cType = try? CType(cdeclType: type), convention != .inout {
      _ = cType
      return LoweredParameters(
        cdeclParameters: [
          SwiftParameter(
            convention: convention,
            parameterName: parameterName,
            type: type,
            canBeDirectReturn: true
          )
        ]
      )
    }

    switch type {
    case .metatype:
      return LoweredParameters(
        cdeclParameters: [
          SwiftParameter(
            convention: .byValue,
            parameterName: parameterName,
            type: .nominal(
              SwiftNominalType(
                nominalTypeDecl: swiftStdlibTypes[.unsafeRawPointer]
              )
            ),
            canBeDirectReturn: true
          )
        ]
      )

    case .nominal(let nominal):
      // Types from the Swift standard library that we know about.
      if let knownType = nominal.nominalTypeDecl.knownStandardLibraryType,
         convention != .inout {
        // Typed pointers are mapped down to their raw forms in cdecl entry
        // points. These can be passed through directly.
        if knownType == .unsafePointer || knownType == .unsafeMutablePointer {
          let isMutable = knownType == .unsafeMutablePointer
          let cdeclPointerType = isMutable
            ? swiftStdlibTypes[.unsafeMutableRawPointer]
            : swiftStdlibTypes[.unsafeRawPointer]
          return LoweredParameters(
            cdeclParameters: [
              SwiftParameter(
                convention: convention,
                parameterName: parameterName + "_pointer",
                type: SwiftType.nominal(
                  SwiftNominalType(nominalTypeDecl: cdeclPointerType)
                ),
                canBeDirectReturn: true
              )
            ]
          )
        }

        // Typed buffer pointers are mapped down to a (pointer, count) pair
        // so those parts can be passed through directly.
        if knownType == .unsafeBufferPointer || knownType == .unsafeMutableBufferPointer {
          let isMutable = knownType == .unsafeMutableBufferPointer
          let cdeclPointerType = isMutable
            ? swiftStdlibTypes[.unsafeMutableRawPointer]
            : swiftStdlibTypes[.unsafeRawPointer]
          return LoweredParameters(
            cdeclParameters: [
              SwiftParameter(
                convention: convention,
                parameterName: parameterName + "_pointer",
                type: SwiftType.nominal(
                  SwiftNominalType(nominalTypeDecl: cdeclPointerType)
                )
              ),
              SwiftParameter(
                convention: convention,
                parameterName: parameterName + "_count",
                type: SwiftType.nominal(
                  SwiftNominalType(nominalTypeDecl: swiftStdlibTypes[.int])
                )
              )
            ]
          )
        }

        // 'String' is passed in by C string. i.e. 'UnsafePointer<Int8>' ('const uint8_t *')
        if knownType == .string {
          return LoweredParameters(
            cdeclParameters: [
              SwiftParameter(
                convention: convention,
                parameterName: parameterName,
                type: .nominal(SwiftNominalType(
                  nominalTypeDecl: swiftStdlibTypes.unsafePointerDecl,
                  genericArguments: [
                    .nominal(SwiftNominalType(nominalTypeDecl: swiftStdlibTypes[.int8]))
                  ]))
              )
            ]
          )
        }
      }

      // Arbitrary types are lowered to raw pointers that either "are" the
      // reference (for classes and actors) or will point to it.
      let canBeDirectReturn = switch nominal.nominalTypeDecl.kind {
        case .actor, .class: true
        case .enum, .protocol, .struct: false
      }
      let isReferenceType = (nominal.nominalTypeDecl.kind == .class || nominal.nominalTypeDecl.kind == .actor)

      let isMutable = (convention == .inout || isReferenceType)
      return LoweredParameters(
        cdeclParameters: [
          SwiftParameter(
            convention: .byValue,
            parameterName: parameterName,
            type: .nominal(
              SwiftNominalType(
                nominalTypeDecl: isMutable
                  ? swiftStdlibTypes[.unsafeMutableRawPointer]
                  : swiftStdlibTypes[.unsafeRawPointer]
              )
            ),
            canBeDirectReturn: canBeDirectReturn
          )
        ]
      )

    case .tuple(let tuple):
      let parameterNames = tuple.indices.map { "\(parameterName)_\($0)" }
      let loweredElements: [LoweredParameters] = try zip(tuple, parameterNames).map { element, name in
        try lowerParameter(element, convention: convention, parameterName: name)
      }
      return LoweredParameters(
        cdeclParameters: loweredElements.flatMap { $0.cdeclParameters }
      )

    case .function(let fn) where fn.parameters.isEmpty && fn.resultType.isVoid:
      return LoweredParameters(cdeclParameters: [
        SwiftParameter(
          convention: .byValue,
          parameterName: parameterName,
          type: .function(SwiftFunctionType(convention: .c, parameters: [], resultType: fn.resultType))
        )
      ])

    case .function, .optional:
      // FIXME: Support other function types than '() -> Void'.
      throw LoweringError.unhandledType(type)
    }
  }

  /// Given a Swift function signature that represents a @_cdecl function,
  /// produce the equivalent C function with the given name.
  ///
  /// Lowering to a @_cdecl function should never produce a
  @_spi(Testing)
  public func cdeclToCFunctionLowering(
    _ cdeclSignature: SwiftFunctionSignature,
    cName: String
  ) -> CFunction {
    return try! CFunction(cdeclSignature: cdeclSignature, cName: cName)
  }
}

struct LabeledArgument<Element> {
  var label: String?
  var argument: Element
}

extension LabeledArgument: Equatable where Element: Equatable { }


struct LoweredParameters: Equatable {
  /// The lowering of the parameters at the C level in Swift.
  var cdeclParameters: [SwiftParameter]
}

enum LoweringError: Error {
  case inoutNotSupported(SwiftType)
  case unhandledType(SwiftType)
}

@_spi(Testing)
public struct LoweredFunctionSignature: Equatable {
  var original: SwiftFunctionSignature
  public var cdecl: SwiftFunctionSignature

  var parameters: [LoweredParameters]
  var result: LoweredParameters
}

extension LoweredFunctionSignature {
  /// Produce the `@_cdecl` thunk for this lowered function signature that will
  /// call into the original function.

  fileprivate func cdeclThunk(
    cName: String,
    stdlibTypes: SwiftStandardLibraryTypes,
    withResult resultBuilder: (_ selfExpr: ExprSyntax?, _ arguments: [ExprSyntax]) -> ExprSyntax
  ) -> FunctionDeclSyntax {
    var loweredCDecl = cdecl.createFunctionDecl(cName)

    // Add the @_cdecl attribute.
    let cdeclAttribute: AttributeSyntax = "@_cdecl(\(literal: cName))\n"
    loweredCDecl.attributes.append(.attribute(cdeclAttribute))

    // Make it public.
    loweredCDecl.modifiers.append(
      DeclModifierSyntax(name: .keyword(.public), trailingTrivia: .space)
    )

    // Lower "self", if there is one.
    let parametersToLower: ArraySlice<LoweredParameters>
    let cdeclToOriginalSelf: ExprSyntax?
    if let originalSelf = original.selfParameter {
      switch originalSelf {
      case .instance(let originalSelfParam):
        // The instance was provided to the cdecl thunk, so convert it to
        // its Swift representation.
        cdeclToOriginalSelf = try! ConversionStep(
          cdeclToSwift: originalSelfParam.type
        ).asExprSyntax(
          isSelf: true,
          placeholder: originalSelfParam.parameterName ?? "self"
        )
        parametersToLower = parameters.dropLast()

      case .staticMethod(let selfType):
        // Static methods use the Swift type as "self", but there is no
        // corresponding cdecl parameter.
        cdeclToOriginalSelf = "\(raw: selfType.description)"
        parametersToLower = parameters[...]

      case .initializer(let selfType):
        // Initializers use the Swift type to create the instance. Save it
        // as the "self" expression. There is no corresponding cdecl parameter.
        cdeclToOriginalSelf = "\(raw: selfType.description)"
        parametersToLower = parameters[...]
      }
    } else {
      cdeclToOriginalSelf = nil
      parametersToLower = parameters[...]
    }

    // Lower the remaining arguments.
    let cdeclToOriginalArguments = parametersToLower.indices.map { index in
      let originalParam = original.parameters[index]
      return try! ConversionStep(
        cdeclToSwift: originalParam.type
      ).asExprSyntax(
        isSelf: false,
        placeholder: originalParam.parameterName ?? "_\(index)"
      )
    }

    // Build the result.
    let result = resultBuilder(cdeclToOriginalSelf, cdeclToOriginalArguments)

    // Handle the return.
    if cdecl.result.type.isVoid && original.result.type.isVoid {
      // Nothing to return.
      loweredCDecl.body = """
        {
          \(result)
        }
        """
    } else {
      // Determine the necessary conversion of the Swift return value to the
      // cdecl return value.
      let resultConversion = try! ConversionStep(
        swiftToCDecl: original.result.type,
        stdlibTypes: stdlibTypes
      )

      var bodyItems: [CodeBlockItemSyntax] = []

      // If there are multiple places in the result conversion that reference
      // the placeholder, capture the result of the call in a local variable.
      // This prevents us from calling the function multiple times.
      let originalResult: ExprSyntax
      if resultConversion.placeholderCount > 1 {
        bodyItems.append("""
            let __swift_result = \(result)
          """
        )
        originalResult = "__swift_result"
      } else {
        originalResult = result
      }

      if cdecl.result.type.isVoid {
        // Indirect return. This is a regular return in Swift that turns
        // into an assignment via the indirect parameters. We do a cdeclToSwift
        // conversion on the left-hand side of the tuple to gather all of the
        // indirect output parameters we need to assign to, and the result
        // conversion is the corresponding right-hand side.
        let cdeclParamConversion = try! ConversionStep(
          cdeclToSwift: original.result.type
        )

        // For each indirect result, initialize the value directly with the
        // corresponding element in the converted result.
        bodyItems.append(
          contentsOf: cdeclParamConversion.initialize(
            placeholder: "_result",
            from: resultConversion,
            otherPlaceholder: originalResult.description
          )
        )
      } else {
        // Direct return. Just convert the expression.
        let convertedResult = resultConversion.asExprSyntax(
          isSelf: true,
          placeholder: originalResult.description
        )

        bodyItems.append("""
            return \(convertedResult)
          """
        )
      }

      loweredCDecl.body = CodeBlockSyntax(
        leftBrace: .leftBraceToken(trailingTrivia: .newline),
        statements: .init(bodyItems.map { $0.with(\.trailingTrivia, .newline) })
      )
    }

    return loweredCDecl
  }

  @_spi(Testing)
  public func cdeclThunk(
    cName: String,
    swiftFunctionName: String,
    stdlibTypes: SwiftStandardLibraryTypes
  ) -> FunctionDeclSyntax {
    self.cdeclThunk(cName: cName, stdlibTypes: stdlibTypes) { selfExpr, arguments in
      // Build call expression.
      let callee: ExprSyntax = if let selfExpr {
        if case .initializer(_)  = original.selfParameter {
          // Don't bother to create explicit ${Self}.init expresssion.
          selfExpr
        } else {
          ExprSyntax(MemberAccessExprSyntax(base: selfExpr, name: .identifier(swiftFunctionName)))
        }
      } else {
        ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(swiftFunctionName)))
      }
      return ExprSyntax(FunctionCallExprSyntax(calledExpression: callee) {
        for (i, argument) in arguments.enumerated() {
          LabeledExprSyntax(label: original.parameters[i].argumentLabel, expression: argument)
        }
      })
    }
  }
}

extension ConversionStep {
  /// Form a set of statements that initializes the placeholders within
  /// the given conversion step from ones in the other step, effectively
  /// exploding something like `(a, (b, c)) = (d, (e, f))` into
  /// separate initializations for a, b, and c from d, e, and f, respectively.
  func initialize(
    placeholder: String,
    from otherStep: ConversionStep,
    otherPlaceholder: String
  ) -> [CodeBlockItemSyntax] {
    // Create separate assignments for each element in paired tuples.
    if case .tuplify(let elements) = self,
        case .tuplify(let otherElements) = otherStep {
      assert(elements.count == otherElements.count)

      return elements.indices.flatMap { index in
        elements[index].initialize(
          placeholder: "\(placeholder)_\(index)",
          from: otherElements[index],
          otherPlaceholder: "\(otherPlaceholder)_\(index)"
        )
      }
    }

    // Look through "pass indirectly" steps; they do nothing here.
    if case .passIndirectly(let conversionStep) = self {
      return conversionStep.initialize(
        placeholder: placeholder,
        from: otherStep,
        otherPlaceholder: otherPlaceholder
      )
    }

    // The value we're initializing from.
    let otherExpr = otherStep.asExprSyntax(
      isSelf: false,
      placeholder: otherPlaceholder
    )

    // If we have a "pointee" on where we are performing initialization, we
    // need to instead produce an initialize(to:) call.
    if case .pointee(let innerSelf) = self {
      let selfPointerExpr = innerSelf.asExprSyntax(
        isSelf: true,
        placeholder: placeholder
      )

      return [ "  \(selfPointerExpr).initialize(to: \(otherExpr))" ]
    }

    let selfExpr = self.asExprSyntax(isSelf: true, placeholder: placeholder)
    return [ "  \(selfExpr) = \(otherExpr)" ]
  }
}

extension Swift2JavaTranslator {
  @_spi(Testing)
  public func lowerVariableAccessor(
    _ decl: VariableDeclSyntax,
    enclosingType: TypeSyntax? = nil,
    kind: VariableAccessorKind,
  ) throws -> LoweredVariableAccessor {
    let binding = decl.bindings.first!

    let enclosingType: SwiftType? = if let enclosingType {
      try SwiftType(enclosingType, symbolTable: self.symbolTable)
    } else {
      nil
    }
    let accessorSignature = try SwiftFunctionSignature(decl, kind: kind, enclosingType: enclosingType, symbolTable: self.symbolTable)

    return LoweredVariableAccessor(loweredFunc: try lowerFunctionSignature(accessorSignature))
  }
}

@_spi(Testing)
public struct LoweredVariableAccessor: Equatable {
  var loweredFunc: LoweredFunctionSignature
}

extension LoweredVariableAccessor {
  /// Produce the `@_cdecl` thunk for this lowered function signature that will
  /// call into the original function.
  @_spi(Testing)
  public func cdeclThunk(
    cName: String,
    swiftVariableName: String,
    stdlibTypes: SwiftStandardLibraryTypes
  ) -> FunctionDeclSyntax {
    loweredFunc.cdeclThunk(cName: cName, stdlibTypes: stdlibTypes) { selfExpr, arguments in
      let variableRefExpr: ExprSyntax = if let selfExpr {
        ExprSyntax(MemberAccessExprSyntax(base: selfExpr, name: .identifier(swiftVariableName)))
      } else {
        ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(swiftVariableName)))
      }

      if arguments.isEmpty {
        // Getter.
        return variableRefExpr
      } else {
        // Setter.
        assert(arguments.count == 1)
        return ExprSyntax("\(variableRefExpr) = \(arguments[0])")
      }
    }
  }
}

