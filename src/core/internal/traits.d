/**
 * Contains traits for runtime internal usage.
 *
 * Copyright: Copyright Digital Mars 2014 -.
 * License:   $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Martin Nowak
 * Source: $(DRUNTIMESRC core/internal/_traits.d)
 */
module core.internal.traits;

/// taken from std.typetuple.TypeTuple
template TypeTuple(TList...)
{
    alias TypeTuple = TList;
}

T trustedCast(T, U)(auto ref U u) @trusted pure nothrow
{
    return cast(T)u;
}

template Unconst(T)
{
         static if (is(T U ==   immutable U)) alias Unconst = U;
    else static if (is(T U == inout const U)) alias Unconst = U;
    else static if (is(T U == inout       U)) alias Unconst = U;
    else static if (is(T U ==       const U)) alias Unconst = U;
    else                                      alias Unconst = T;
}

/// taken from std.traits.Unqual
template Unqual(T)
{
    version (none) // Error: recursive alias declaration @@@BUG1308@@@
    {
             static if (is(T U ==     const U)) alias Unqual = Unqual!U;
        else static if (is(T U == immutable U)) alias Unqual = Unqual!U;
        else static if (is(T U ==     inout U)) alias Unqual = Unqual!U;
        else static if (is(T U ==    shared U)) alias Unqual = Unqual!U;
        else                                    alias Unqual =        T;
    }
    else // workaround
    {
             static if (is(T U ==          immutable U)) alias Unqual = U;
        else static if (is(T U == shared inout const U)) alias Unqual = U;
        else static if (is(T U == shared inout       U)) alias Unqual = U;
        else static if (is(T U == shared       const U)) alias Unqual = U;
        else static if (is(T U == shared             U)) alias Unqual = U;
        else static if (is(T U ==        inout const U)) alias Unqual = U;
        else static if (is(T U ==        inout       U)) alias Unqual = U;
        else static if (is(T U ==              const U)) alias Unqual = U;
        else                                             alias Unqual = T;
    }
}

/// used to declare an extern(D) function that is defined in a different module
template externDFunc(string fqn, T:FT*, FT) if(is(FT == function))
{
    static if (is(FT RT == return) && is(FT Args == function))
    {
        import core.demangle : mangleFunc;
        enum decl = {
            string s = "extern(D) RT externDFunc(Args)";
            foreach (attr; __traits(getFunctionAttributes, FT))
                s ~= " " ~ attr;
            return s ~ ";";
        }();
        pragma(mangle, mangleFunc!T(fqn)) mixin(decl);
    }
    else
        static assert(0);
}

template staticIota(int beg, int end)
{
    static if (beg + 1 >= end)
    {
        static if (beg >= end)
        {
            alias staticIota = TypeTuple!();
        }
        else
        {
            alias staticIota = TypeTuple!(+beg);
        }
    }
    else
    {
        enum mid = beg + (end - beg) / 2;
        alias staticIota = TypeTuple!(staticIota!(beg, mid), staticIota!(mid, end));
    }
}

enum hasElaborateDestructor() = false;

template hasElaborateDestructor(S)
{
    static if (__traits(isStaticArray, S) && S.length)
    {
        enum bool hasElaborateDestructor = hasElaborateDestructor!(typeof(S.init[0]));
    }
    else static if (is(S == struct))
    {
        enum hasElaborateDestructor = hasMember!(S, "__dtor")
            || hasElaborateDestructor!(typeof(S.tupleof[0 .. $ - __traits(isNested, S)]));
    }
    else
    {
        enum bool hasElaborateDestructor = false;
    }
}

template hasElaborateDestructor(S...) if (S.length > 1)
{
    enum hasElaborateDestructor = hasElaborateDestructor!(S[0 .. $/2]) ||
        hasElaborateDestructor!(S[$/2 .. $]);
}

template hasMember(S, string mem)
{
    static if (is(T == struct) || is(T == class) || is(T == union) || is(T == interface))
        enum hasMember =
        {
            foreach (m; __traits(getMember, S))
                if (m == mem) return true;
            return false;
        }();
    else
        enum hasMember = false;
}
