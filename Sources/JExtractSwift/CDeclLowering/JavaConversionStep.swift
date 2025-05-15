//===----------------------------------------------------------------------===//
//
// JavaConversionStep.swift
//
// Provides conversion logic between Java types (JNI/native) and C types.
// Used for generating JNI bridges or Swift/Java interoperability shims.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Represents a conversion step between a Java type and a C type.
enum JavaConversionStep {
    case identity
    case javaIntToCInt(javaExpr: String)
    case javaDoubleToCDouble(javaExpr: String)
    case javaBooleanToCBool(javaExpr: String)
    case javaStringToCString(javaExpr: String)
    case javaObjectToCPointer(javaExpr: String)
    case cIntToJavaInt(cExpr: String)
    case cDoubleToJavaDouble(cExpr: String)
    case cBoolToJavaBoolean(cExpr: String)
    case cStringToJavaString(cExpr: String)
    case cPointerToJavaObject(cExpr: String)
    // Add more as needed

    /// Returns a string of C code (or Swift, as needed) performing the conversion from Java to C.
    func javaToCExpr() -> String {
        switch self {
        case .identity:
            return "/* no conversion needed */"
        case .javaIntToCInt(let javaExpr):
            return "(int)(\(javaExpr))"
        case .javaDoubleToCDouble(let javaExpr):
            return "(double)(\(javaExpr))"
        case .javaBooleanToCBool(let javaExpr):
            return "(\(javaExpr) ? 1 : 0)"
        case .javaStringToCString(let javaExpr):
            // In JNI, you might use GetStringUTFChars
            return "(*env)->GetStringUTFChars(env, \(javaExpr), NULL)"
        case .javaObjectToCPointer(let javaExpr):
            return "(void*)(\(javaExpr))"
        default:
            return "/* not implemented */"
        }
    }

    /// Returns a string of Java code performing the conversion from C to Java.
    func cToJavaExpr() -> String {
        switch self {
        case .identity:
            return "/* no conversion needed */"
        case .cIntToJavaInt(let cExpr):
            return "(int)(\(cExpr))"
        case .cDoubleToJavaDouble(let cExpr):
            return "(double)(\(cExpr))"
        case .cBoolToJavaBoolean(let cExpr):
            return "(\(cExpr) != 0)"
        case .cStringToJavaString(let cExpr):
            // In JNI: NewStringUTF
            return "(*env)->NewStringUTF(env, \(cExpr))"
        case .cPointerToJavaObject(let cExpr):
            return "(jobject)(\(cExpr))"
        default:
            return "/* not implemented */"
        }
    }
}
