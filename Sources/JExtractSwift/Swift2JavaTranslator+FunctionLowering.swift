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
              loweredResult.cdeclParameters[0].isPrimitive {
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

    let loweredSelf = try signature.selfParameter.map { selfParameter in
      try lowerParameter(
        selfParameter.type,
        convention: selfParameter.convention,
        parameterName: selfParameter.parameterName ?? "self"
      )
    }

    // Collect all of the lowered parameters for the @_cdecl function.
    var allLoweredParameters: [LoweredParameters] = []
    var cdeclLoweredParameters: [SwiftParameter] = []
    allLoweredParameters.append(contentsOf: loweredParameters)
    cdeclLoweredParameters.append(
      contentsOf: loweredParameters.flatMap { $0.cdeclParameters }
    )

    let cdeclResult: SwiftResult
    if indirectResult {
      cdeclLoweredParameters.append(
        contentsOf: loweredResult.cdeclParameters
      )
      cdeclResult = .init(convention: .direct, type: .tuple([]))
    } else if loweredResult.cdeclParameters.count == 1,
              let primitiveResult = loweredResult.cdeclParameters.first {
      cdeclResult = .init(convention: .direct, type: primitiveResult.type)
    } else if loweredResult.cdeclParameters.count == 0 {
      cdeclResult = .init(convention: .direct, type: .tuple([]))
    } else {
      fatalError("Improper lowering of result for \(signature)")
    }

    if let loweredSelf {
      allLoweredParameters.append(loweredSelf)
      cdeclLoweredParameters.append(contentsOf: loweredSelf.cdeclParameters)
    }

    let cdeclSignature = SwiftFunctionSignature(
      isStaticOrClass: false,
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
    switch type {
    case .function, .optional:
      throw LoweringError.unhandledType(type)

    case .metatype(let instanceType):
      return LoweredParameters(
        cdeclToOriginal: .unsafeCastPointer(
          .placeholder,
          swiftType: instanceType
        ),
        cdeclParameters: [
          SwiftParameter(
            convention: .byValue,
            parameterName: parameterName,
            type: .nominal(
              SwiftNominalType(
                nominalTypeDecl: swiftStdlibTypes[.unsafeRawPointer]
              )
            )
          )
        ]
      )

    case .nominal(let nominal):
      // Types from the Swift standard library that we know about.
      if nominal.nominalTypeDecl.moduleName == "Swift",
          nominal.nominalTypeDecl.parent == nil {
        // Primitive types
        if let loweredPrimitive = try lowerParameterPrimitive(nominal, convention: convention, parameterName: parameterName) {
          return loweredPrimitive
        }

        // Swift pointer types.
        if let loweredPointers = try lowerParameterPointers(nominal, convention: convention, parameterName: parameterName) {
          return loweredPointers
        }
      }

      let mutable = (convention == .inout)
      let loweringStep: ConversionStep
      switch nominal.nominalTypeDecl.kind {
      case .actor, .class:
        loweringStep = 
          .unsafeCastPointer(.placeholder, swiftType: type)
      case .enum, .struct, .protocol:
        loweringStep =
          .passIndirectly(.pointee(.typedPointer(.placeholder, swiftType: type)))
      }

      return LoweredParameters(
        cdeclToOriginal: loweringStep,
        cdeclParameters: [
          SwiftParameter(
            convention: .byValue,
            parameterName: parameterName,
            type: .nominal(
              SwiftNominalType(
                nominalTypeDecl: mutable
                  ? swiftStdlibTypes[.unsafeMutableRawPointer]
                  : swiftStdlibTypes[.unsafeRawPointer]
              )
            )
          )
        ]
      )

    case .tuple(let tuple):
      let parameterNames = tuple.indices.map { "\(parameterName)_\($0)" }
      let loweredElements: [LoweredParameters] = try zip(tuple, parameterNames).map { element, name in
        try lowerParameter(element, convention: convention, parameterName: name)
      }
      return LoweredParameters(
        cdeclToOriginal: .tuplify(loweredElements.map { $0.cdeclToOriginal }),
        cdeclParameters: loweredElements.flatMap { $0.cdeclParameters }
      )
    }
  }

  func lowerParameterPrimitive(
    _ nominal: SwiftNominalType,
    convention: SwiftParameterConvention,
    parameterName: String
  ) throws -> LoweredParameters? {
    let nominalName = nominal.nominalTypeDecl.name
    let type = SwiftType.nominal(nominal)

    // Swift types that map directly to Java primitive types.
    if let primitiveType = JavaType(swiftTypeName: nominalName) {
      // FIXME: Should be using C types here, not Java types.
      _ = primitiveType

      // We cannot handle inout on primitive types.
      if convention == .inout {
        throw LoweringError.inoutNotSupported(type)
      }

      return LoweredParameters(
        cdeclToOriginal: .placeholder,
        cdeclParameters: [
          SwiftParameter(
            convention: convention,
            parameterName: parameterName,
            type: type,
            isPrimitive: true
          )
        ]
      )
    }

    // The Swift "Int" type, which maps to whatever the pointer-sized primitive
    // integer type is in Java (int for 32-bit, long for 64-bit).
    if nominalName == "Int" {
      // We cannot handle inout on primitive types.
      if convention == .inout {
        throw LoweringError.inoutNotSupported(type)
      }

      return LoweredParameters(
        cdeclToOriginal: .placeholder,
        cdeclParameters: [
          SwiftParameter(
            convention: convention,
            parameterName: parameterName,
            type: type,
            isPrimitive: true
          )
        ]
      )
    }

    return nil
  }

  func lowerParameterPointers(
    _ nominal: SwiftNominalType,
    convention: SwiftParameterConvention,
    parameterName: String
  ) throws -> LoweredParameters? {
    let nominalName = nominal.nominalTypeDecl.name
    let type = SwiftType.nominal(nominal)

    guard let (requiresArgument, mutable, hasCount) = nominalName.isNameOfSwiftPointerType else {
      return nil
    }

    // At the @_cdecl level, make everything a raw pointer.
    let cdeclPointerType = mutable
      ? swiftStdlibTypes[.unsafeMutableRawPointer]
      : swiftStdlibTypes[.unsafeRawPointer]
    var cdeclToOriginal: ConversionStep
    switch (requiresArgument, hasCount) {
    case (false, false):
      cdeclToOriginal = .placeholder

    case (true, false):
      cdeclToOriginal = .typedPointer(
        .explodedComponent(.placeholder, component: "pointer"),
        swiftType: nominal.genericArguments![0]
      )

    case (false, true):
      cdeclToOriginal = .initialize(type, arguments: [
        LabeledArgument(label: "start", argument: .explodedComponent(.placeholder, component: "pointer")),
        LabeledArgument(label: "count", argument: .explodedComponent(.placeholder, component: "count"))
      ])

    case (true, true):
      cdeclToOriginal = .initialize(
        type,
        arguments: [
          LabeledArgument(
            label: "start",
            argument: .typedPointer(
              .explodedComponent(.placeholder, component: "pointer"),
              swiftType: nominal.genericArguments![0])
          ),
          LabeledArgument(
            label: "count",
            argument: .explodedComponent(.placeholder, component: "count")
          )
        ]
      )
    }

    let lowered: [(SwiftParameter, ForeignValueLayout)]
    if hasCount {
      lowered = [
        (
          SwiftParameter(
            convention: convention,
            parameterName: parameterName + "_pointer",
            type: SwiftType.nominal(
              SwiftNominalType(nominalTypeDecl: cdeclPointerType)
            )
          ),
          .SwiftPointer
        ),
        (
          SwiftParameter(
            convention: convention,
            parameterName: parameterName + "_count",
            type: SwiftType.nominal(
              SwiftNominalType(nominalTypeDecl: swiftStdlibTypes[.int])
            )
          ),
          .SwiftInt
         )
      ]
    } else {
      lowered = [
        (
          SwiftParameter(
            convention: convention,
            parameterName: parameterName + "_pointer",
            type: SwiftType.nominal(
              SwiftNominalType(nominalTypeDecl: cdeclPointerType)
            )
          ),
          .SwiftPointer
        ),
      ]
    }

    return LoweredParameters(
      cdeclToOriginal: cdeclToOriginal,
      cdeclParameters: lowered.map(\.0)
    )
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
    assert(cdeclSignature.selfParameter == nil)

    let cResultType = try! swiftStdlibTypes.cdeclToCLowering(cdeclSignature.result.type)
    let cParameters = cdeclSignature.parameters.map { parameter in
      CParameter(
        name: parameter.parameterName,
        type: try! swiftStdlibTypes.cdeclToCLowering(parameter.type).parameterDecay
      )
    }

    return CFunction(
      resultType: cResultType,
      name: cName,
      parameters: cParameters,
      isVariadic: false
    )
  }
}

struct LabeledArgument<Element> {
  var label: String?
  var argument: Element
}

extension LabeledArgument: Equatable where Element: Equatable { }


struct LoweredParameters: Equatable {
  /// The steps needed to get from the @_cdecl parameters to the original function
  /// parameter.
  var cdeclToOriginal: ConversionStep

  /// The lowering of the parameters at the C level in Swift.
  var cdeclParameters: [SwiftParameter]
}

extension LoweredParameters {
  /// Produce an expression that computes the argument for this parameter
  /// when calling the original function from the cdecl entrypoint.
  func cdeclToOriginalArgumentExpr(isSelf: Bool, value: String)-> ExprSyntax {
    cdeclToOriginal.asExprSyntax(isSelf: isSelf, placeholder: value)
  }
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
  @_spi(Testing)
  public func cdeclThunk(cName: String, inputFunction: FunctionDeclSyntax) -> FunctionDeclSyntax {
    var loweredCDecl = cdecl.createFunctionDecl(cName)

    // Add the @_cdecl attribute.
    let cdeclAttribute: AttributeSyntax = "@_cdecl(\(literal: cName))\n"
    loweredCDecl.attributes.append(.attribute(cdeclAttribute))

    // Create the body.

    // Lower "self", if there is one.
    let parametersToLower: ArraySlice<LoweredParameters>
    let cdeclToOriginalSelf: ExprSyntax?
    if let originalSelfParam = original.selfParameter,
       let selfParameter = parameters.last {
      cdeclToOriginalSelf = selfParameter.cdeclToOriginalArgumentExpr(isSelf: true, value: originalSelfParam.parameterName ?? "self")
      parametersToLower = parameters.dropLast()
    } else {
      cdeclToOriginalSelf = nil
      parametersToLower = parameters[...]
    }

    // Lower the remaining arguments.
    let cdeclToOriginalArguments = zip(parametersToLower, original.parameters).map { lowering, originalParam in
      let cdeclToOriginalArg = lowering.cdeclToOriginalArgumentExpr(isSelf: false, value: originalParam.parameterName ?? "FIXME")
      if let argumentLabel = originalParam.argumentLabel {
        return "\(argumentLabel): \(cdeclToOriginalArg.description)"
      } else {
        return cdeclToOriginalArg.description
      }
    }

    // Form the call expression.
    var callExpression: ExprSyntax = "\(inputFunction.name)(\(raw: cdeclToOriginalArguments.joined(separator: ", ")))"
    if let cdeclToOriginalSelf {
      callExpression = "\(cdeclToOriginalSelf).\(callExpression)"
    }

    // Handle the return.
    if cdecl.result.type.isVoid && original.result.type.isVoid {
      // Nothing to return.
      loweredCDecl.body = """
        {
          \(callExpression)
        }
        """
    } else if cdecl.result.type.isVoid {
      // Indirect return. This is a regular return in Swift that turns
      // into a
      loweredCDecl.body = """
        {
          \(result.cdeclToOriginalArgumentExpr(isSelf: true, value: "_result")) = \(callExpression)
        }
        """
    } else {
      // Direct return.
      loweredCDecl.body = """
        {
          return \(callExpression)
        }
        """
    }

    return loweredCDecl
  }
}
