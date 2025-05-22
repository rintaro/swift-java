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
import SwiftParser
import SwiftSyntax

//final class Swift2JavaTranslateVisitor {
//  func translate(decl node: DeclSyntax, into typeContext: ImportedNominalType?) {
//    switch node.as(DeclSyntaxEnum.self) {
//
//    case .structDecl(let node):
//      self.translate(nominalTypeDecl: node, into: typeContext)
//    case .enumDecl(let node):
//      self.translate(nominalTypeDecl: node, into: typeContext)
//    case .classDecl(let node):
//      self.translate(nominalTypeDecl: node, into: typeContext)
//    case .actorDecl(let node):
//      self.translate(nominalTypeDecl: node, into: typeContext)
//    case .protocolDecl(let node):
//      self.translate(nominalTypeDecl: node, into: typeContext)
//    case .extensionDecl(let node):
//      self.translate(extensionDecl: node, into: typeContext)
//
//    case .functionDecl(let node):
//      self.translate(functionDecl: node, into: typeContext)
//    case .subscriptDecl(let node):
//      self.translate(subscriptDecl: node, into: typeContext)
//    case .variableDecl(let node):
//      self.translate(variableDecl: node, into: typeContext)
//    }
//  }
//
//  func translate(sourceFile node: SourceFileSyntax) {
//    for code in node.statements {
//      guard let decl = code.item.as(DeclSyntax.self) else {
//        return
//      }
//      self.translate(decl: decl, into: nil)
//    }
//  }
//
//  func translate(nominalTypeDecl node: some NamedDeclSyntax & DeclGroupSyntax & WithAttributesSyntax & WithModifiersSyntax, into typeContext: ImportedNominalType?) {
//    guard let importedNominal = translator.importedNominalType(node, typeContext) else {
//      return
//    }
//    for member in node.memberBlock.members {
//      self.translate(decl: member.decl, into: importedNominal)
//    }
//  }
//
//  func translate(extensionDecl node: ExtensionDeclSyntax, into typeContext: ImportedNominalType?) throws {
//    guard typeContext == nil else {
//      return
//    }
//  }
//
//  func translate(functionDecl node: FunctionDeclSyntax, into typeContext: ImportedNominalType?) throws {
//    self.translator.importedFunc(node, typeContext)
//  }
//  func translate(subscriptDecl node: SubscriptDeclSyntax, into typeContext: ImportedNominalType?) throws {
//    SwiftFunctionSignature(node, enclosingType: <#T##SwiftType?#>, symbolTable: SwiftSymbolTable)
//  }
//  func translate(variableDecl node: VariableDeclSyntax, into typeContext: ImportedNominalType?) throws {
//    SwiftFunctionSignature(node, enclosingType: <#T##SwiftType?#>, symbolTable: SwiftSymbolTable)
//  }
//}

final class Swift2JavaVisitor: SyntaxVisitor {
  let translator: Swift2JavaTranslator

  /// The Swift module we're visiting declarations in
  let moduleName: String

  /// The target java package we are going to generate types into eventually,
  /// store this along with type names as we import them.
  let targetJavaPackage: String

  /// Type context stack associated with the syntax.
  var typeContext: [(syntaxID: Syntax.ID, type: ImportedNominalType)] = []

  /// Innermost type context.
  var currentType: ImportedNominalType? { typeContext.last?.type }

  var currentSwiftType: SwiftType? {
    guard let currentType else { return nil }
    return .nominal(SwiftNominalType(nominalTypeDecl: currentType.swiftNominal))
  }

  /// The current type name as a nested name like A.B.C.
  var currentTypeName: String? { self.currentType?.swiftNominal.qualifiedName }

  var log: Logger { translator.log }

  init(moduleName: String, targetJavaPackage: String, translator: Swift2JavaTranslator) {
    self.moduleName = moduleName
    self.targetJavaPackage = targetJavaPackage
    self.translator = translator

    super.init(viewMode: .all)
  }

  /// Push specified type to the type context associated with the syntax.
  func pushTypeContext(syntax: some SyntaxProtocol, importedNominal: ImportedNominalType) {
    typeContext.append((syntax.id, importedNominal))
  }

  /// Pop type context if the current context is associated with the syntax.
  func popTypeContext(syntax: some SyntaxProtocol) -> Bool {
    if typeContext.last?.syntaxID == syntax.id {
      typeContext.removeLast()
      return true
    } else {
      return false
    }
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    log.debug("Visit \(node.kind): '\(node.qualifiedNameForDebug)'")
    guard let importedNominalType = translator.importedNominalType(node, parent: self.currentType) else {
      return .skipChildren
    }

    self.pushTypeContext(syntax: node, importedNominal: importedNominalType)
    return .visitChildren
  }

  override func visitPost(_ node: ClassDeclSyntax) {
    if self.popTypeContext(syntax: node) {
      log.debug("Completed import: \(node.kind) \(node.name)")
    }
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    log.debug("Visit \(node.kind): \(node.qualifiedNameForDebug)")
    guard let importedNominalType = translator.importedNominalType(node, parent: self.currentType) else {
      return .skipChildren
    }

    self.pushTypeContext(syntax: node, importedNominal: importedNominalType)
    return .visitChildren
  }

  override func visitPost(_ node: StructDeclSyntax) {
    if self.popTypeContext(syntax: node) {
      log.debug("Completed import: \(node.kind) \(node.qualifiedNameForDebug)")
    }
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    // Resolve the extended type of the extension as an imported nominal, and
    // recurse if we found it.
    guard let importedNominalType = translator.importedNominalType(node.extendedType) else {
      return .skipChildren
    }

    self.pushTypeContext(syntax: node, importedNominal: importedNominalType)
    return .visitChildren
  }

  override func visitPost(_ node: ExtensionDeclSyntax) {
    if self.popTypeContext(syntax: node) {
      log.debug("Completed import: \(node.kind) \(node.qualifiedNameForDebug)")
    }
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.shouldImport(log: log) else {
      return .skipChildren
    }

    self.log.debug("Import function: \(node.kind) \(node.name)")

    guard let swiftSignature = try? SwiftFunctionSignature(
      node,
      enclosingType: currentSwiftType,
      symbolTable: translator.symbolTable
    ) else {
      
      return .skipChildren
    }

    let returnTy: TypeSyntax
    if let returnClause = node.signature.returnClause {
      returnTy = returnClause.type
    } else {
      returnTy = "Swift.Void"
    }

    let params: [ImportedParam]
    let javaResultType: TranslatedType
    do {
      params = try node.signature.parameterClause.parameters.map { param in
        // TODO: more robust parameter handling
        // TODO: More robust type handling
        ImportedParam(
          syntax: param,
          type: try cCompatibleType(for: param.type)
        )
      }

      javaResultType = try cCompatibleType(for: returnTy)
    } catch {
      self.log.info("Unable to import function \(node.name) - \(error)")
      return .skipChildren
    }

    let fullName = "\(node.name.text)"

    let funcDecl = ImportedFunc(
      module: self.translator.swiftModuleName,
      decl: node.trimmed,
      parent: currentTypeName.map { translator.importedTypes[$0] }??.translatedType,
      identifier: fullName,
      accessorKind: nil,
      returnType: javaResultType,
      parameters: params,
      swiftFuncSignature: swiftSignature
    )

    if let currentTypeName {
      log.debug("Record method in \(currentTypeName)")
      translator.importedTypes[currentTypeName]?.methods.append(funcDecl)
    } else {
      translator.importedGlobalFuncs.append(funcDecl)
    }

    return .skipChildren
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.shouldImport(log: log) else {
      return .skipChildren
    }

    guard let binding = node.bindings.first else {
      return .skipChildren
    }

    let fullName = "\(binding.pattern.trimmed)"

    // TODO: filter out kinds of variables we cannot import

    self.log.debug("Import variable: \(node.kind) '\(node.qualifiedNameForDebug)'")

    let returnTy: TypeSyntax
    if let typeAnnotation = binding.typeAnnotation {
      returnTy = typeAnnotation.type
    } else {
      returnTy = "Swift.Void"
    }

    let javaResultType: TranslatedType
    do {
      javaResultType = try cCompatibleType(for: returnTy)
    } catch {
      log.info("Unable to import variable '\(node.qualifiedNameForDebug)' - \(error)")
      return .skipChildren
    }

    var varDecl = ImportedVariable(
      module: self.translator.swiftModuleName,
      parentName: currentTypeName.map { translator.importedTypes[$0] }??.translatedType,
      identifier: fullName,
      returnType: javaResultType,
      syntax: node
    )

    if let currentTypeName {
      log.debug("Record variable in \(currentTypeName)")
      translator.importedTypes[currentTypeName]!.variables.append(varDecl)
    } else {
      translator.importedGlobalVariables.append(varDecl)
    }

    return .skipChildren
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let currentTypeName,
      let currentType = translator.importedTypes[currentTypeName]
    else {
      fatalError("Initializer must be within a current type, was: \(node)")
    }
    guard node.shouldImport(log: log) else {
      return .skipChildren
    }

    self.log.debug("Import initializer: \(node.kind) '\(node.qualifiedNameForDebug)'")

    guard let swiftSignature = try? SwiftFunctionSignature(
      node,
      enclosingType: self.currentSwiftType,
      symbolTable: self.translator.symbolTable
    ) else {
      return .skipChildren
    }

    let params: [ImportedParam]
    do {
      params = try node.signature.parameterClause.parameters.map { param in
        // TODO: more robust parameter handling
        // TODO: More robust type handling
        return ImportedParam(
          syntax: param,
          type: try cCompatibleType(for: param.type)
        )
      }
    } catch {
      self.log.info("Unable to import initializer due to \(error)")
      return .skipChildren
    }

    let initIdentifier =
      "init(\(String(params.flatMap { "\($0.effectiveName ?? "_"):" })))"

    var funcDecl = ImportedFunc(
      module: self.translator.swiftModuleName,
      decl: node.trimmed,
      parent: currentType.translatedType,
      identifier: initIdentifier,
      accessorKind: nil,
      returnType: currentType.translatedType,
      parameters: params,
      swiftFuncSignature: swiftSignature
    )
    funcDecl.isInit = true

    log.debug(
      "Record initializer method in \(currentType.javaType.description): \(funcDecl.identifier)")
    translator.importedTypes[currentTypeName]!.initializers.append(funcDecl)

    return .skipChildren
  }

  override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    return .skipChildren
  }
}

extension DeclSyntaxProtocol where Self: WithModifiersSyntax & WithAttributesSyntax {
  func shouldImport(log: Logger) -> Bool {
    guard accessControlModifiers.contains(where: { $0.isPublic }) else {
      log.trace("Skip import '\(self.qualifiedNameForDebug)': not public")
      return false
    }
    guard !attributes.contains(where: { $0.isJava }) else {
      log.trace("Skip import '\(self.qualifiedNameForDebug)': is Java")
      return false
    }

    if let node = self.as(InitializerDeclSyntax.self) {
      let isFailable = node.optionalMark != nil

      if isFailable {
        log.warning("Skip import '\(self.qualifiedNameForDebug)': failable initializer")
        return false
      }
    }

    return true
  }
}
