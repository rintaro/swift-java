//
//import SwiftSyntax
//
//func lowerVariableAccessor(
//  _ signature: SwiftVariableSignature,
//  kind: VariableAccessKind,
//) throws -> LoweredVariableAccessr {
//  let loweredSelf: LoweredParameter? = switch signature.selfParameter {
//  case .instance(let selfParameter):
//    try lowerParameter(
//      selfParameter.type,
//      convention: selfParameter.convention,
//      parameterName: selfParameter.parameterName ?? "self"
//    )
//  case nil, .initializer(_), .staticMethod(_):
//    nil
//  }
//
//  let loweredParameters: [LoweredParameter] = switch kind {
//  case .set:
//    [try lowerParameter(signature.type, convention: .byValue, parameterName: "newValue")]
//  case .get:
//    []
//  }
//
//  return LoweredVariableAccessr(
//    original: signature,
//    accessorKind: kind,
//    selfParameter: loweredSelf,
//    parameters: loweredParameters
//  )
//}
//
//protocol SwiftAPIThunk {
//  var selfParameter: LoweredParameter? { get }
//  var parameters: [LoweredParameter] { get }
//  var result: LoweredResult { get }
//
//  func asSwiftAPICallExpr(selfExpr: ExprSyntax, arguments: [ExprSyntax]) -> ExprSyntax
//}
//
///// Represent a cdecl
//struct LoweredStorageAccessor: Equatable {
//  var original: SwiftStorageSignature
//
//  var accessorKind: StorageAccessorKind
//  var selfParameter: LoweredParameter?
//  var parameters: [LoweredParameter]
//  var result: LoweredResult
//}
//
//extension LoweredStorageAccessor: SwiftAPIThunk {
//  func asSwiftAPICallExpr(selfExpr: ExprSyntax, arguments: [ExprSyntax]) -> ExprSyntax {
//    switch accessorKind {
//    case .get:
//      switch original.selfParameter {
//      case .instance(let swiftParameter):
//        <#code#>
//      case .staticMethod(let swiftType):
//        <#code#>
//      case .initializer(let swiftType):
//        <#code#>
//      }
//    }
//  }
//}
//
//extension SwiftAPIThunk {
//  var allLoweredParameters: [SwiftParameter] {
//    var all: [SwiftParameter] = []
//    // Original parameters.
//    for loweredParam in parameters {
//      all += loweredParam.cdeclParameters
//    }
//    // Self.
//    if let selfParameter = self.selfParameter {
//      all += selfParameter.cdeclParameters
//    }
//    // Out parameters.
//    all += result.cdeclOutParameters
//    return all
//  }
//}
