/**
 * Implementation of exception handling support routines.
 *
 * Copyright: Copyright Digital Mars 1999 - 2013.
 * License: Distributed under the
 *      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
 *    (See accompanying file LICENSE)
 * Authors:   Walter Bright
 * Source: $(DRUNTIMESRC src/rt/deh.d)
 */

module rt.deh;

extern (C)
{
    void _d_createTrace(Object o, void* context) /*nothrow @nogc*/
    {
        auto t = cast(Throwable) o;

        if (t is null || t.callstack !is null) // in case of rethrow
            return;

        if (Runtime.tracePrinter)
            t.callstack = getCallStack(ptr);
        else if (auto h = Runtime.traceHandler)
            t.info = h(ptr);
    }
}

version (Win32)
    public import rt.deh_win32;
else version (Win64)
    public import rt.deh_win64_posix;
else version (Posix)
    public import rt.deh_win64_posix;
else
    static assert (0, "Unsupported architecture");
