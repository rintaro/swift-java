//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift.org project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift.org project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftBasicFormat
import SwiftParser
import SwiftSyntax

struct SwiftThunkTranslator {

  let st: Swift2JavaTranslator

  init(_ st: Swift2JavaTranslator) {
    self.st = st
  }

  func renderGlobalThunks() -> [DeclSyntax] {
    var decls: [DeclSyntax] = []

    for decl in st.importedGlobalVariables {
      decls.append(contentsOf: render(forVariable: decl))
    }

    for decl in st.importedGlobalFuncs {
      decls.append(contentsOf: render(forFunc: decl))
    }

    return decls
  }

  /// Render all the thunks that make Swift methods accessible to Java.
  func renderThunks(forType nominal: ImportedNominalType) -> [DeclSyntax] {
    var decls: [DeclSyntax] = []
    decls.reserveCapacity(nominal.initializers.count + nominal.methods.count)

    decls.append(renderSwiftTypeAccessor(nominal))

    for decl in nominal.initializers {
      decls.append(contentsOf: renderSwiftInitAccessor(decl))
    }

    for decl in nominal.variables {
      decls.append(contentsOf: render(forVariable: decl))
    }

    for decl in nominal.methods {
      decls.append(contentsOf: render(forFunc: decl))
    }

    // TODO: handle variables
    //    for v in nominal.variables {
    //      if let acc = v.accessorFunc(kind: .get) {
    //        decls.append(contentsOf: render(forFunc: acc))
    //      }
    //      if let acc = v.accessorFunc(kind: .set) {
    //        decls.append(contentsOf: render(forFunc: acc))
    //      }
    //    }

    return decls
  }

  /// Accessor to get the `T.self` of the Swift type, without having to rely on mangled name lookups.
  func renderSwiftTypeAccessor(_ nominal: ImportedNominalType) -> DeclSyntax {
    let funcName = SwiftKitPrinting.Names.getType(
      module: st.swiftModuleName,
      nominal: nominal)

    return
      """
      @_cdecl("\(raw: funcName)")
      public func \(raw: funcName)() -> UnsafeMutableRawPointer /* Any.Type */ {
        return unsafeBitCast(\(raw: nominal.swiftNominal.qualifiedName).self, to: UnsafeMutableRawPointer.self)
      }
      """
  }

  func renderSwiftInitAccessor(_ function: ImportedFunc) -> [DeclSyntax] {
    guard let parent = function.parent else {
      fatalError(
        "Cannot render initializer accessor if init function has no parent! Was: \(function)")
    }

    let thunkName = self.st.thunkNameRegistry.functionThunkName(
      module: st.swiftModuleName, decl: function)

    let lowering = CdeclLowering(swiftStdlibTypes: st.swiftStdlibTypes)
    if let loweredSignature = try? lowering.lowerFunctionSignature(function.swiftSignature) {
      let thunkFunc = loweredSignature.cdeclThunk(cName: thunkName, swiftFunctionName: parent.swiftTypeName, stdlibTypes: st.swiftStdlibTypes)
      return [DeclSyntax(thunkFunc)]
    }

    fatalError("unsupported")
  }

  func render(forVariable decl: ImportedVariable) -> [DeclSyntax] {
    st.log.trace("Rendering thunks for: \(decl.identifier)")
    var thunkFuncs: [DeclSyntax] = []

    let lowering = CdeclLowering(swiftStdlibTypes: st.swiftStdlibTypes)
    for kind in decl.supportedAccessorKinds {
      if
        let accessor = decl.accessorFunc(kind: kind, symbolTable: st.symbolTable),
        let loweredSignature = try? lowering.lowerFunctionSignature(accessor.swiftSignature)
      {
        let thunkName = st.thunkNameRegistry.functionThunkName(module: st.swiftModuleName, decl: accessor)
        let loweredVariable = LoweredVariableAccessor(loweredFunc: loweredSignature)
        let thunkFunc = loweredVariable.cdeclThunk(cName: thunkName, swiftVariableName: decl.identifier, stdlibTypes: st.swiftStdlibTypes)
        thunkFuncs.append(DeclSyntax(thunkFunc))
      }
    }
    return thunkFuncs
  }

  func render(forFunc decl: ImportedFunc) -> [DeclSyntax] {
    st.log.trace("Rendering thunks for: \(decl.baseIdentifier)")
    let thunkName = st.thunkNameRegistry.functionThunkName(module: st.swiftModuleName, decl: decl)

    let lowering = CdeclLowering(swiftStdlibTypes: st.swiftStdlibTypes)
    if let loweredSignature = try? lowering.lowerFunctionSignature(decl.swiftSignature) {
      let thunkFunc = loweredSignature.cdeclThunk(cName: thunkName, swiftFunctionName: decl.baseIdentifier, stdlibTypes: st.swiftStdlibTypes)
      return [DeclSyntax(thunkFunc)]
    }

    fatalError("unsupported \(decl)")
  }
}
