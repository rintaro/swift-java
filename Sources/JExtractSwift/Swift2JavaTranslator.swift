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
import JavaTypes
import SwiftBasicFormat
import SwiftParser
import SwiftSyntax

/// Takes swift interfaces and translates them into Java used to access those.
public final class Swift2JavaTranslator {
  static let SWIFT_INTERFACE_SUFFIX = ".swiftinterface"

  package var log = Logger(label: "translator", logLevel: .info)

  // ==== Input

  struct Input {
    let filePath: String
    let syntax: SourceFileSyntax
  }

  var inputs: [Input] = []

  // ==== Output configuration
  let javaPackage: String

  var javaPackagePath: String {
    javaPackage.replacingOccurrences(of: ".", with: "/")
  }

  // ==== Output state

  package var importedGlobalVariables: [ImportedVariable] = []

  package var importedGlobalFuncs: [ImportedFunc] = []

  /// A mapping from Swift type names (e.g., A.B) over to the imported nominal
  /// type representation.
  package var importedTypes: [String: ImportedNominalType] = [:]

  package var swiftStdlibTypes: SwiftStandardLibraryTypes

  let symbolTable: SwiftSymbolTable

  var thunkNameRegistry: ThunkNameRegistry = ThunkNameRegistry()

  /// The name of the Swift module being translated.
  var swiftModuleName: String {
    symbolTable.moduleName
  }

  public init(
    javaPackage: String,
    swiftModuleName: String
  ) {
    self.javaPackage = javaPackage
    self.symbolTable = SwiftSymbolTable(parsedModuleName: swiftModuleName)

    // Create a mock of the Swift standard library.
    var parsedSwiftModule = SwiftParsedModuleSymbolTable(moduleName: "Swift")
    self.swiftStdlibTypes = SwiftStandardLibraryTypes(into: &parsedSwiftModule)
    self.symbolTable.importedModules.append(parsedSwiftModule.symbolTable)
  }
}

// ===== --------------------------------------------------------------------------------------------------------------
// MARK: Analysis

extension Swift2JavaTranslator {
  /// The primitive Java type to use for Swift's Int type, which follows the
  /// size of a pointer.
  ///
  /// FIXME: Consider whether to extract this information from the Swift
  /// interface file, so that it would be 'int' for 32-bit targets or 'long' for
  /// 64-bit targets but make the Java code different for the two, vs. adding
  /// a checked truncation operation at the Java/Swift board.
  var javaPrimitiveForSwiftInt: JavaType { .long }

  package func add(filePath: String, text: String) {
    log.trace("Adding: \(filePath)")
    let sourceFileSyntax = Parser.parse(source: text)
    self.inputs.append(Input(filePath: filePath, syntax: sourceFileSyntax))
  }

  /// Convenient method for analyzing single file.
  package func analyze(
    file: String,
    text: String
  ) throws {
    self.add(filePath: file, text: text)
    try self.analyze()
  }

  /// Analyze registered inputs.
  func analyze() throws {
    prepareForTranslation()

    let visitor = Swift2JavaVisitor(
      moduleName: self.swiftModuleName,
      targetJavaPackage: self.javaPackage,
      translator: self
    )

    for input in self.inputs {
      log.trace("Analyzing \(input.filePath)")
      visitor.walk(input.syntax)
    }
  }

  package func prepareForTranslation() {
    // First, register top-level and nested nominal types to the symbol table.
    for input in inputs {
      symbolTable.addNominalTypeDeclarations(input.syntax)
    }

    // Register nested nominal in extensions to the symbol table.
    // The work queue is required because, the extending type might be declared
    // in another extension that hasn't been processed. E.g.:
    //
    //   extension Outer.Inner { struct Deeper {} }
    //   extension Outer { struct Inner {} }
    //   struct Outer {}
    //
    func handleExtension(_ extensionDecl: ExtensionDeclSyntax) -> Bool {
      // Try to resolve the type referenced by this extension declaration.
      // If it fails, we'll try again later.
      guard let extendedType = try? SwiftType(extensionDecl.extendedType, symbolTable: self.symbolTable) else {
        return false
      }
      guard let extendedNominal = extendedType.asNominalTypeDeclaration else {
        // Extending type was not a nominal type. Ignore it.
        return true
      }

      // We have successfully resolved the extended type. Record it and
      // remove the extension from the list of unresolved extensions.
      self.symbolTable.parsedModule.addExtension(extensionDecl, extending: extendedNominal)
      return true
    }

    var unresolvedExtensions: [ExtensionDeclSyntax] = []
    for input in inputs {
      // Find extensions.
      for statement in input.syntax.statements {
        // We only care about declarations.
        if case .decl(let decl) = statement.item,
          let extNode = decl.as(ExtensionDeclSyntax.self) {
          let resolved = handleExtension(extNode)
          if !resolved {
            unresolvedExtensions.append(extNode)
          }
        }
      }
    }
    
    while unresolvedExtensions.isEmpty {
      let numExtensionsBefore = unresolvedExtensions.count
      unresolvedExtensions.removeAll(where: handleExtension(_:))

      // If we didn't resolve anything, we're done.
      if numExtensionsBefore == unresolvedExtensions.count {
        break
      }
      assert(numExtensionsBefore > unresolvedExtensions.count)
    }
  }
}

// ===== --------------------------------------------------------------------------------------------------------------
// MARK: Defaults

extension Swift2JavaTranslator {
  /// Default formatting options.
  static let defaultFormat = BasicFormat(indentationWidth: .spaces(2))

  /// Default set Java imports for every generated file
  static let defaultJavaImports: Array<String> = [
    "org.swift.swiftkit.*",
    "org.swift.swiftkit.SwiftKit",
    "org.swift.swiftkit.util.*",

    // Necessary for native calls and type mapping
    "java.lang.foreign.*",
    "java.lang.invoke.*",
    "java.util.Arrays",
    "java.util.stream.Collectors",
    "java.util.concurrent.atomic.*",
    "java.nio.charset.StandardCharsets",
  ]

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Type translation
extension Swift2JavaTranslator {
  /// Try to resolve the given nominal declaration node into its imported representation.
  func importedNominalType(
    _ nominalNode: some DeclGroupSyntax & NamedDeclSyntax & WithModifiersSyntax & WithAttributesSyntax,
    parent: ImportedNominalType?
  ) -> ImportedNominalType? {
    if !nominalNode.shouldImport(log: log) {
      return nil
    }

    guard let nominal = symbolTable.lookupType(nominalNode.name.text, parent: parent?.swiftNominal) else {
      return nil
    }
    return self.importedNominalType(nominal)
  }

  /// Try to resolve the given nominal type node into its imported representation.
  func importedNominalType(
    _ typeNode: TypeSyntax
  ) -> ImportedNominalType? {
    guard let swiftType = try? SwiftType(typeNode, symbolTable: self.symbolTable) else {
      return nil
    }
    guard let swiftNominalDecl = swiftType.asNominalTypeDeclaration else {
      return nil
    }
    guard let nominalNode = symbolTable.parsedModule.nominalTypeSyntaxNodes[swiftNominalDecl] else {
      return nil
    }
    guard nominalNode.shouldImport(log: log) else {
      return nil
    }
    return importedNominalType(swiftNominalDecl)
  }

  func importedNominalType(_ nominal: SwiftNominalTypeDeclaration) -> ImportedNominalType? {
    let fullName = nominal.qualifiedName

    if let alreadyImported = importedTypes[fullName] {
      return alreadyImported
    }

    // Determine the nominal type kind.
    let kind: NominalTypeKind
    switch nominal.kind {
    case .actor:  kind = .actor
    case .class:  kind = .class
    case .enum:   kind = .enum
    case .struct: kind = .struct
    default: return nil
    }

    let importedNominal = ImportedNominalType(
      swiftNominal: nominal,
      javaType: .class(
        package: javaPackage,
        name: nominal.qualifiedName
      ),
      kind: kind
    )

    importedTypes[fullName] = importedNominal
    return importedNominal
  }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

public struct Swift2JavaTranslatorError: Error {
  let message: String

  public init(message: String) {
    self.message = message
  }
}
