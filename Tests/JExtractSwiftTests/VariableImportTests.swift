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

final class VariableImportTests {
  let class_interfaceFile =
    """
    // swift-interface-format-version: 1.0
    // swift-compiler-version: Apple Swift version 6.0 effective-5.10 (swiftlang-6.0.0.7.6 clang-1600.0.24.1)
    // swift-module-flags: -target arm64-apple-macosx15.0 -enable-objc-interop -enable-library-evolution -module-name MySwiftLibrary
    import Darwin.C
    import Darwin
    import Swift
    import _Concurrency
    import _StringProcessing
    import _SwiftConcurrencyShims

    public class MySwiftClass {
      public var counterInt: Int
    }
    """

  @Test("Import: var counter: Int")
  func variable_int() throws {
    let st = Swift2JavaTranslator(
      javaPackage: "com.example.swift",
      swiftModuleName: "FakeModule"
    )
    st.log.logLevel = .error

    try assertOutput(
      st, input: class_interfaceFile, .java,
      detectChunkByInitialLines: 7,
      expectedChunks: [
        """
        private static class swiftjava_FakeModule_MySwiftClass_counterInt$get {
          public static final FunctionDescriptor DESC = FunctionDescriptor.of(
              /* -> */SWIFT_INT,
              /* self: */SWIFT_POINTER
          );
          public static final MemorySegment ADDR =
              FakeModule.findOrThrow("swiftjava_FakeModule_MySwiftClass_counterInt$get");
          public static final MethodHandle HANDLE = Linker.nativeLinker().downcallHandle(ADDR, DESC);
        } 
        """,
        """
        /**
         * Downcall to Swift:
         * {@snippet lang=swift :
         * public var counterInt: Int
         * }
         */
        public static long getCounterInt(java.lang.foreign.MemorySegment self$) {
            var mh$ = swiftjava_FakeModule_MySwiftClass_counterInt$get.HANDLE;
            try {
                if (SwiftKit.TRACE_DOWNCALLS) {
                    SwiftKit.traceDowncall(self$);
                }
                return (long) mh$.invokeExact(self$);
            } catch (Throwable ex$) {
                throw new AssertionError("should not reach here", ex$);
            }
        }
        """,
        """
        /**
         * Downcall to Swift:
         * {@snippet lang=swift :
         * public var counterInt: Int
         * }
         */
        public long getCounterInt() {
          if (this.$state$destroyed.get()) {
            throw new IllegalStateException("Attempted to call method on already destroyed instance of " + getClass().getSimpleName() + "!");
          }
          return (long) getCounterInt($memorySegment());
        }
        """,
        
        """
        private static class swiftjava_FakeModule_MySwiftClass_counterInt$set {
          public static final FunctionDescriptor DESC = FunctionDescriptor.ofVoid(
            /* newValue: */SWIFT_INT,
            /* self: */SWIFT_POINTER
          );
          public static final MemorySegment ADDR =
            FakeModule.findOrThrow("swiftjava_FakeModule_MySwiftClass_counterInt$set");
          public static final MethodHandle HANDLE = Linker.nativeLinker().downcallHandle(ADDR, DESC);
        }
        """,
        """
        /**
         * Downcall to Swift:
         * {@snippet lang=swift :
         * public var counterInt: Int
         * }
         */
        public static void setCounterInt(long newValue, java.lang.foreign.MemorySegment self$) {
          var mh$ = swiftjava_FakeModule_MySwiftClass_counterInt$set.HANDLE;
          try {
            if (SwiftKit.TRACE_DOWNCALLS) {
              SwiftKit.traceDowncall(newValue, self$);
            }
            mh$.invokeExact(newValue, self$);
          } catch (Throwable ex$) {
            throw new AssertionError("should not reach here", ex$);
          }
        }
        """,
        """
        /**
         * Downcall to Swift:
         * {@snippet lang=swift :
         * public var counterInt: Int
         * }
         */
        public void setCounterInt(long newValue) {
          if (this.$state$destroyed.get()) {
            throw new IllegalStateException("Attempted to call method on already destroyed instance of " + getClass().getSimpleName() + "!");
          }
          setCounterInt(newValue, $memorySegment());
        }
        """,
      ]
    )
  }
}
