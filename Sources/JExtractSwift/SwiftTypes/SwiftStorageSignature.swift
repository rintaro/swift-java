//
//  SwiftVariable.swift
//  SwiftJava
//
//  Created by Rintaro Ishizaki on 5/26/25.
//

import SwiftSyntax

enum StorageAccessorKind {
  case get, set
}

/// Provides a complete signature for a Swift storage (i.e. `var`/`let` and
/// `subscript`), which includes its parameters and the value type.
struct SwiftStorageSignature: Equatable {
  var selfParameter: SwiftSelfParameter?

  /// Non-nil if the representing storage is a subscript.
  var parameters: [SwiftParameter]?

  /// The value type.
  var type: SwiftType

  var supportedAccessors: [StorageAccessorKind]
}

extension SwiftStorageSignature {
  /// Create signature from a variable syntax node.
  init(_ varNode: VariableDeclSyntax, enclosingType: SwiftType?, symbolTable: SwiftSymbolTable) throws {
    guard let binding = varNode.bindings.first, varNode.bindings.count == 1 else {
      throw SwiftFunctionTranslationError.multipleBindings(varNode)
    }

    // If this is a member of a type, so we will have a self parameter. Figure out the
    // type and convention for the self parameter.
    if let enclosingType {
      var isStatic = false
      for modifier in varNode.modifiers {
        switch modifier.name.tokenKind {
        case .keyword(.static): isStatic = true
        case .keyword(.class): throw SwiftFunctionTranslationError.classMethod(modifier.name)
        default: break
        }
      }

      if isStatic {
        self.selfParameter = .staticMethod(enclosingType)
      } else {
        self.selfParameter = .instance(
          SwiftParameter(
            convention: enclosingType.isReferenceType ? .inout : .byValue,
            type: enclosingType
          )
        )
      }
    } else {
      self.selfParameter = nil
    }

    self.parameters = []

    guard let varTypeNode = binding.typeAnnotation?.type else {
      throw SwiftFunctionTranslationError.missingTypeAnnotation(varNode)
    }
    self.type = try SwiftType(varTypeNode, symbolTable: symbolTable)

    // FIXME: handle private(set).
    self.supportedAccessors = if varNode.bindingSpecifier == .keyword(.let) {
      [.get]
    } else if let accessorBlock = binding.accessorBlock, let accessorKinds = supportedAccessors(in: accessorBlock) {
      accessorKinds
    } else {
      [.get, .set]
    }
  }

  /// Create signature from a subscript syntax node.
  init(_ subscriptNode: SubscriptDeclSyntax, enclosingType: SwiftType, symbolTable: SwiftSymbolTable) throws {
    // If this is a member of a type, so we will have a self parameter. Figure out the
    // type and convention for the self parameter.
    var isStatic = false
    for modifier in subscriptNode.modifiers {
      switch modifier.name.tokenKind {
      case .keyword(.static): isStatic = true
      case .keyword(.class): throw SwiftFunctionTranslationError.classMethod(modifier.name)
      default: break
      }
    }

    if isStatic {
      self.selfParameter = .staticMethod(enclosingType)
    } else {
      self.selfParameter = .instance(
        SwiftParameter(
          convention: enclosingType.isReferenceType ? .inout : .byValue,
          type: enclosingType
        )
      )
    }

    self.parameters = try subscriptNode.parameterClause.parameters.map { param in
      try SwiftParameter(param, symbolTable: symbolTable)
    }
    self.type = try SwiftType(subscriptNode.returnClause.type, symbolTable: symbolTable)

    // FIXME: handle private(set).
    self.supportedAccessors = if let accessorBlock = subscriptNode.accessorBlock, let accessorKinds = supportedAccessors(in: accessorBlock) {
      accessorKinds
    } else {
      // Missing accessor block. Let's assume it's readable/writable.
      [.get, .set]
    }
  }

  private func supportedAccessors(in accessorBlock: AccessorBlockSyntax) -> [StorageAccessorKind]? {
    switch accessorBlock.accessors {
    case .getter:
      return [.get]
    case .accessors(let accessors):
      var hasGetter = false
      var hasSetter = false

      for accessor in accessors {
        switch accessor.accessorSpecifier {
        case .keyword(.get), .keyword(._read), .keyword(.unsafeAddress):
          hasGetter = true
        case .keyword(.set), .keyword(._modify), .keyword(.unsafeMutableAddress):
          hasGetter = true
        default: // Ignore willSet/didSet and unknown accessors.
          break
        }
      }

      switch (hasGetter, hasSetter) {
      case (true, true): return [.get, .set]
      case (true, false): return [.get]
      case (false, true): return [.set]
      case (false, false): return nil
      }
    }
  }
}
