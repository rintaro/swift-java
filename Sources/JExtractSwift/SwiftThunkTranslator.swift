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
    decls.reserveCapacity(
      st.importedGlobalVariables.count + st.importedGlobalFuncs.count
    )

    for decl in st.importedGlobalVariables {
      decls.append(contentsOf: render(forFunc: decl))
    }

    for decl in st.importedGlobalFuncs {
      decls.append(contentsOf: render(forFunc: decl))
    }

    return decls
  }

  /// Render all the thunks that make Swift methods accessible to Java.
  func renderThunks(forType nominal: ImportedNominalType) -> [DeclSyntax] {
    var decls: [DeclSyntax] = []
    decls.reserveCapacity(
      1 + nominal.initializers.count + nominal.variables.count + nominal.methods.count
    )

    decls.append(renderSwiftTypeAccessor(nominal))

    for decl in nominal.initializers {
      decls.append(contentsOf: render(forFunc: decl))
    }

    for decl in nominal.variables {
      decls.append(contentsOf: render(forFunc: decl))
    }

    for decl in nominal.methods {
      decls.append(contentsOf: render(forFunc: decl))
    }

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

  func render(forFunc decl: ImportedFunc) -> [DeclSyntax] {
    st.log.trace("Rendering thunks for: \(decl.displayName)")
    let thunkName = st.thunkNameRegistry.functionThunkName(module: st.swiftModuleName, decl: decl)

    let thunkFunc = decl.loweredSignature.cdeclThunk(
      cName: thunkName,
      swiftAPIName: decl.name,
      stdlibTypes: st.swiftStdlibTypes
    )
    return [DeclSyntax(thunkFunc)]
  }
}
