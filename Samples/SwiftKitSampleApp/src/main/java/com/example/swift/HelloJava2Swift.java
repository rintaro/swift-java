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

package com.example.swift;

// Import swift-extract generated sources

// Import javakit/swiftkit support libraries
import org.swift.swiftkit.SwiftArena;
import org.swift.swiftkit.SwiftKit;
        import org.swift.swiftkit.SwiftValueLayout;

import java.lang.foreign.Arena;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;

public class HelloJava2Swift {

    public static void main(String[] args) {
        boolean traceDowncalls = Boolean.getBoolean("jextract.trace.downcalls");
        System.out.println("Property: jextract.trace.downcalls = " + traceDowncalls);

        System.out.print("Property: java.library.path = " + SwiftKit.getJavaLibraryPath());

        examples();
    }

    static void examples() {
        MySwiftLibrary.helloWorld();

        MySwiftLibrary.globalTakeInt(1337);

        long cnt =  MySwiftLibrary.globalWriteString("String from Java");

        SwiftKit.trace("count = " + cnt);

        MySwiftLibrary.globalCallMeRunnable(() -> {
            SwiftKit.trace("running runnable");
        });

        // Example of using an arena; MyClass.deinit is run at end of scope
        try (var arena = SwiftArena.ofConfined()) {
            MySwiftClass obj = new MySwiftClass(arena, 2222, 7777);

            // just checking retains/releases work
            SwiftKit.trace("retainCount = " + SwiftKit.retainCount(obj));
            SwiftKit.retain(obj);
            SwiftKit.trace("retainCount = " + SwiftKit.retainCount(obj));
            SwiftKit.release(obj);
            SwiftKit.trace("retainCount = " + SwiftKit.retainCount(obj));

            obj.setCounter(12);
            SwiftKit.trace("obj.counter = " + obj.getCounter());

            obj.voidMethod();
            obj.takeIntMethod(42);

            MySwiftStruct swiftValue = new MySwiftStruct(arena, 2222, 1111);
            SwiftKit.trace("swiftValue.capacity = " + swiftValue.getCapacity());
        }

        System.out.println("DONE.");
    }

    public static native long jniWriteString(String str);

    public static native long jniGetInt();

}

/*package*/ abstract class SwiftVal {
    protected final MemorySegment selfSegment;
    /*package*/ SwiftVal(MemorySegment segment, SwiftArena arena) {
        this.selfSegment = segment;
        arena.register(this);
    }
}

public class MyClass extends SwiftVal {
    MyClass(MemorySegment segment, SwiftArena arena) {
        super(segment, arena);
    }

    private static class retTuple {
        int tt(Arena a) {
            ValueLayout.JAVA_INT
        }
        static Result invoke(SwiftArena arena) {
            try {
                MemorySegment result_0 = arena.allocate(MyClass.$layout());
                MemorySegment result_1 = arena.allocate(SwiftValueLayout.SWIFT_INT);

                $mh.invokeExact(x, y, result_0, result_1);

                int result1_val = result_1.get(SwiftValueLayout.SWIFT_INT32, 0);
                SwiftKit.getSwiftInt(result_1, 0);

                return new Result(new MyClass(result_0, arena), result1_val);
            } catch (Exception e) {
                throw new AssertionError("Should be unreachable");
            }
        }

    }

    retTuple.Result retTuple(SwiftArena arena) {
        MemorySegment result_0 = arena.allocate(MyClass.$layout());
        MemorySegment result_1_0 = arena.allocate(SwiftValueLayout.SWIFT_INT);
        MemorySegment result_1_1 = arena.allocate(SwiftValueLayout.SWIFT_INT);

    }

    static class Construct {
        static MemorySegment invoke(int x, int y, SwiftArena arena) {
            try {
                MemorySegment result = allocator.allocate(MyClass.$layout());

                $mh.invokeExact(x, y, result);
                // if this is a constructor:
                return result;
                // else
                return new MyClass(result, arena);
            } catch (Exception e) {
                throw new AssertionError("Should be unreachable");
            }
        }
    }

    public MyClass(int x, int y, SwiftArena arena) {
        super(Construct.invoke(x, y, arena), arena);
    }

    public MyClass(int x, int y) {
        this(x, y, SwiftArena.ofAuto());
    }

    int getCount() {
        return Myclas_getCount.invoke(selfSegment);
    }

    MyClass getChild() {
        return MyClass_getChild.invoke(x, y, this);
    }
}