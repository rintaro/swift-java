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

import JExtractSwift
import Testing

final class MethodThunkTests {
  let input =
    """
    import Swift

    public func globalFunc(a: Int32, b: Int64) {}
    public func globalFunc(a: Double, b: Int64) {}
    
    public class MyClass {
      public init(arg: Int32) {}
    }
    """

  @Test("Thunk overloads: globalFunc(a: Int32, b: Int64) & globalFunc(i32: Int32, l: Int64)")
  func thunk_overloads() throws {
    let st = Swift2JavaTranslator(
      javaPackage: "com.example.swift",
      swiftModuleName: "FakeModule"
    )
    st.log.logLevel = .error

    try assertOutput(
      st, input: input, .swift,
      detectChunkByInitialLines: 1,
      expectedChunks:
      [
        """
        @_cdecl("swiftjava_FakeModule_globalFunc_a_b")
        public func swiftjava_FakeModule_globalFunc_a_b(_ a: Int32, _ b: Int64) {
          globalFunc(a: a, b: b)
        }
        """,
        """
        @_cdecl("swiftjava_FakeModule_globalFunc_a_b$1")
        public func swiftjava_FakeModule_globalFunc_a_b$1(_ a: Double, _ b: Int64) {
          globalFunc(a: a, b: b)
        }
        """,
        """
        @_cdecl("swiftjava_getType_FakeModule_MyClass")
        public func swiftjava_getType_FakeModule_MyClass() -> UnsafeMutableRawPointer /* Any.Type */ {
          return unsafeBitCast(MyClass.self, to: UnsafeMutableRawPointer.self)
        }

        @_cdecl("swiftjava_FakeModule_MyClass_init_arg")
        public func swiftjava_FakeModule_MyClass_init_arg(_ arg: Int32) -> UnsafeMutableRawPointer {
          return unsafeBitCast(Unmanaged.passRetained(MyClass(arg: arg)).takeUnretainedValue(), to: UnsafeMutableRawPointer.self)
        }
        """
      ]
    )
  }

}
