/**
 * Written in the D programming language.
 * Module initialization routines.
 *
 * Copyright: Copyright Digital Mars 2000 - 2013.
 * License: Distributed under the
 *      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
 *    (See accompanying file LICENSE)
 * Authors:   Walter Bright, Sean Kelly
 * Source: $(DRUNTIMESRC src/rt/_minfo.d)
 */

module rt.minfo;

import core.stdc.stdlib;  // alloca
import core.stdc.string;  // memcpy
import rt.sections;

enum
{
    MIctorstart  = 0x1,   // we've started constructing it
    MIctordone   = 0x2,   // finished construction
    MIstandalone = 0x4,   // module ctor does not depend on other module
                        // ctors being done first
    MItlsctor    = 8,
    MItlsdtor    = 0x10,
    MIctor       = 0x20,
    MIdtor       = 0x40,
    MIxgetMembers = 0x80,
    MIictor      = 0x100,
    MIunitTest   = 0x200,
    MIimportedModules = 0x400,
    MIlocalClasses = 0x800,
    MIname       = 0x1000,
}

/*****
 * A ModuleGroup is an unordered collection of modules.
 * There is exactly one for:
 *  1. all statically linked in D modules, either directely or as shared libraries
 *  2. each call to rt_loadLibrary()
 */

struct ModuleGroup
{
    this(immutable(ModuleInfo*)[] modules)
    {
        _modules = modules;
    }

    @property immutable(ModuleInfo*)[] modules() const
    {
        return _modules;
    }

    /******************************
     * Allocate and fill in _ctors[] and _tlsctors[].
     * Modules are inserted into the arrays in the order in which the constructors
     * need to be run.
     * Throws:
     *  Exception if it fails.
     */
    void sortCtors()
    {
        import core.stdc.stdio;
        import rt.util.container.array, rt.util.container.hashtab;

        immutable len = _modules.length;
        if (!len)
            return;

        static struct StackRef
        {
            this(uint midx, bool cyclicVisit=false)
            {
                assert(midx < 1u << 8 * _midx.sizeof - 1);
                _midx = midx;
                if (cyclicVisit)
                    _midx |= 1u << 8 * _midx.sizeof - 1;
            }

            uint get() const
            {
                return _midx & ~(1u << 8 * _midx.sizeof - 1);
            }

            bool cyclicVisit()
            {
                return !!(_midx & 1u << 8 * _midx.sizeof - 1);
            }

            alias get this;
            uint _midx;
        }

        Array!StackRef stack;
        Array!(immutable(ModuleInfo*)[]) todoImports;
        todoImports.length = len + 1; // +1 for root (DSO)
        // TODO: reuse GCBits by moving it to rt.util.container or core.internal
        immutable nwords = (len + 8 * size_t.sizeof - 1) / (8 * size_t.sizeof);
        auto ctorstart = cast(size_t*).malloc(nwords * size_t.sizeof);
        auto moddone = cast(size_t*).malloc(nwords * size_t.sizeof);
        if (ctorstart is null || moddone is null)
            assert(0);
        scope (exit) { .free(ctorstart); .free(moddone); }

        int findModule(in ModuleInfo* mi)
        {
            foreach (i, m; _modules)
                if (m is mi) return cast(int)i;
            return -1;
        }

        void sort(ref immutable(ModuleInfo)*[] ctors, uint mask)
        {
            import core.bitop;

            ctors = (cast(immutable(ModuleInfo)**).malloc(len * size_t.sizeof))[0 .. len];
            if (!ctors.ptr)
                assert(0);

            // clean flags
            memset(ctorstart, 0, nwords * size_t.sizeof);
            memset(moddone, 0, nwords * size_t.sizeof);
            size_t stackidx = 0;
            size_t cidx;

            // DSO is root of graph, imports all modules, never gets imported, and gets the highest module index
            stack.insertBack(StackRef(cast(uint)(_modules.length)));
            immutable(ModuleInfo*)[] mods = _modules;

        Louter: while (true)
            {
                while (mods.length)
                {
                    immutable(ModuleInfo)* imp = mods[0];
                    immutable impidx = findModule(imp);
                    mods = mods[1 .. $];
                    auto curModName = stack.back != _modules.length ? _modules[stack.back].name : "root";
                    printf("%.*s %.*s (%zu) %zu %zu\n", cast(int)curModName.length, curModName.ptr, cast(int)imp.name.length, imp.name.ptr, impidx, mods.length, stack.length);


                    if (impidx < 0 || bt(moddone, impidx))
                    {
                        /* If the module can't be found among the ones to be
                         * sorted it's an imported module from another DSO.
                         * Those don't need to be considered during sorting as
                         * the OS is responsible for the DSO load order and
                         * module construction is done during DSO loading.
                         */
                    }
                    else if (bt(ctorstart, impidx))
                    {
                        if (imp.flags & mask) // module with ctor/dtor
                        {
                            /* Trace back to the begin of the cycle.
                             */
                            bool ctorInCycle;
                            size_t start = stack.length;
                            while (start--)
                            {
                                printf("traceback %zu\n", start);
                                auto smidx = stack[start];
                                if (smidx == impidx)
                                    break;
                                //assert(!(_modules[smidx].flags & MIstandalone), "unexpected standalone module on TODO stack");
                                if (!(_modules[smidx].flags & MIstandalone) && _modules[smidx].flags & mask)
                                    ctorInCycle = true;
                            }
                            assert(stack[start] == impidx);
                            if (ctorInCycle)
                            {
                                /* This is an illegal cycle, no partial order can be established
                                 * because the import chain have contradicting ctor/dtor
                                 * constraints.
                                 */
                                string msg = "Aborting: Cycle detected between modules with ";
                                if (mask & (MIctor | MIdtor))
                                    msg ~= "shared ";
                                msg ~= "ctors/dtors:\n";
                                foreach (cmidx; stack[start .. stackidx])
                                {
                                    msg ~= _modules[cmidx].name;
                                    if (_modules[cmidx].flags & mask)
                                        msg ~= '*';
                                    msg ~= " ->\n";
                                }
                                msg ~= _modules[impidx].name ~ '*';
                                free();
                                throw new Exception(msg);
                            }
                            else
                            {
                                /* This is also a cycle, but the import chain does not constrain
                                 * the order of initialization, either because the imported
                                 * modules have no ctors or the ctors are standalone.
                                 */
                            }

                            auto impmods = todoImports[impidx];
                            if (impmods.length) // construct the rest of the module's imports first
                            {
                                todoImports[stack.back] = mods; // save current iteration state
                                enum cyclicVisit = true;
                                stack.insertBack(StackRef(impidx, cyclicVisit)); // recurse
                                mods = impmods;
                                printf("recursive visit %.*s %zu\n", cast(int)imp.name.length, imp.name.ptr, mods.length);
                            }
                        }
                    }
                    else if (imp.importedModules.length)
                    {
                        // has dependencies => defer and recurse
                        bts(ctorstart, impidx);
                        todoImports[stack.back] = mods; // save current iteration state
                        stack.insertBack(StackRef(impidx)); // recurse
                        assert(!todoImports[impidx].length);
                        mods = imp.importedModules; // continue to construct module's imports
                    }
                    else
                    {
                        // no dependencies => sort in
                        if (imp.flags & mask)
                            ctors[cidx++] = imp;
                        bts(moddone, impidx);
                        printf("done %zu\n", impidx);
                    }
                }

                // finished constructing current module's imports
                auto midx = stack.back;
                todoImports[midx] = null;
                if (midx != _modules.length && // not root (DSO)
                    !stack.back.cyclicVisit) // mark as done unless this is a cyclic visit of a module
                {
                    printf("done %zu\n", midx);
                    if (bts(moddone, midx))
                        assert(0, "unexpected moddone");
                    if (_modules[midx].flags & mask)
                        ctors[cidx++] = _modules[midx];
                }

                // continue with previous module
                for (stack.popBack; !stack.empty; stack.popBack)
                {
                    midx = stack.back;
                    mods = todoImports[midx];
                    if (mods.length) // continue constructing the rest of it's imports
                        continue Louter;
                    // all imports are constructed when popping the first (non-cyclic) visit of a module
                    if (midx != _modules.length && // not root (DSO)
                        !stack.back.cyclicVisit)
                    {
                        printf("done %zu\n", midx);
                        if (bts(moddone, midx))
                            assert(0, "unexpected moddone");
                        if (_modules[midx].flags & mask)
                            ctors[cidx++] = _modules[midx];
                    }
                }
                break;
            }
            // store final number and shrink array
            ctors = (cast(immutable(ModuleInfo)**).realloc(ctors.ptr, cidx * size_t.sizeof))[0 .. cidx];
        }

        /* Do two passes: ctor/dtor, tlsctor/tlsdtor
         */
        sort(_ctors, MIctor | MIdtor);
        fprintf(stderr, "_ctors.length %zu\n", _ctors.length);
        sort(_tlsctors, MItlsctor | MItlsdtor);
        fprintf(stderr, "_tlsctors.length %zu\n", _tlsctors.length);
    }

    void runCtors()
    {
        // run independent ctors
        runModuleFuncs!(m => m.ictor)(_modules);
        // sorted module ctors
        runModuleFuncs!(m => m.ctor)(_ctors);
    }

    void runTlsCtors()
    {
        runModuleFuncs!(m => m.tlsctor)(_tlsctors);
    }

    void runTlsDtors()
    {
        runModuleFuncsRev!(m => m.tlsdtor)(_tlsctors);
    }

    void runDtors()
    {
        runModuleFuncsRev!(m => m.dtor)(_ctors);
    }

    void free()
    {
        if (_ctors.ptr)
            .free(_ctors.ptr);
        _ctors = null;
        if (_tlsctors.ptr)
            .free(_tlsctors.ptr);
        _tlsctors = null;
        // _modules = null; // let the owner free it
    }

private:
    immutable(ModuleInfo*)[]  _modules;
    immutable(ModuleInfo)*[]    _ctors;
    immutable(ModuleInfo)*[] _tlsctors;
}


/********************************************
 * Iterate over all module infos.
 */

int moduleinfos_apply(scope int delegate(immutable(ModuleInfo*)) dg)
{
    foreach (ref sg; SectionGroup)
    {
        foreach (m; sg.modules)
        {
            // TODO: Should null ModuleInfo be allowed?
            if (m !is null)
            {
                if (auto res = dg(m))
                    return res;
            }
        }
    }
    return 0;
}

/********************************************
 * Module constructor and destructor routines.
 */

extern (C)
{
void rt_moduleCtor()
{
    foreach (ref sg; SectionGroup)
    {
        sg.moduleGroup.sortCtors();
        sg.moduleGroup.runCtors();
    }
}

void rt_moduleTlsCtor()
{
    foreach (ref sg; SectionGroup)
    {
        sg.moduleGroup.runTlsCtors();
    }
}

void rt_moduleTlsDtor()
{
    foreach_reverse (ref sg; SectionGroup)
    {
        sg.moduleGroup.runTlsDtors();
    }
}

void rt_moduleDtor()
{
    foreach_reverse (ref sg; SectionGroup)
    {
        sg.moduleGroup.runDtors();
        sg.moduleGroup.free();
    }
}

version (Win32)
{
    // Alternate names for backwards compatibility with older DLL code
    void _moduleCtor()
    {
        rt_moduleCtor();
    }

    void _moduleDtor()
    {
        rt_moduleDtor();
    }

    void _moduleTlsCtor()
    {
        rt_moduleTlsCtor();
    }

    void _moduleTlsDtor()
    {
        rt_moduleTlsDtor();
    }
}
}

/********************************************
 */

void runModuleFuncs(alias getfp)(const(immutable(ModuleInfo)*)[] modules)
{
    foreach (m; modules)
    {
        if (auto fp = getfp(m))
            (*fp)();
    }
}

void runModuleFuncsRev(alias getfp)(const(immutable(ModuleInfo)*)[] modules)
{
    foreach_reverse (m; modules)
    {
        if (auto fp = getfp(m))
            (*fp)();
    }
}

unittest
{
    import core.stdc.stdio;
    puts("========== unittest ==========\n");

    static void assertThrown(T : Throwable, E)(lazy E expr, string msg, size_t line=__LINE__)
    {
        try
            expr;
        catch (T)
            return;
        import core.exception : onAssertErrorMsg;
        onAssertErrorMsg(__FILE__, line, msg);
    }

    static void stub()
    {
    }

    static struct UTModuleInfo
    {
        this(uint flags)
        {
            mi._flags = flags;
        }

        void setImports(immutable(ModuleInfo)*[] imports...)
        {
            import core.bitop;
            assert(flags & MIimportedModules);

            immutable nfuncs = popcnt(flags & (MItlsctor|MItlsdtor|MIctor|MIdtor|MIictor));
            immutable size = nfuncs * (void function()).sizeof +
                size_t.sizeof + imports.length * (ModuleInfo*).sizeof;
            assert(size <= pad.sizeof);

            pad[nfuncs] = imports.length;
            .memcpy(&pad[nfuncs+1], imports.ptr, imports.length * imports[0].sizeof);
        }

        immutable ModuleInfo mi;
        size_t[8] pad;
        alias mi this;
    }

    static UTModuleInfo mockMI(uint flags)
    {
        auto mi = UTModuleInfo(flags | MIimportedModules);
        auto p = cast(void function()*)&mi.pad;
        if (flags & MItlsctor) *p++ = &stub;
        if (flags & MItlsdtor) *p++ = &stub;
        if (flags & MIctor) *p++ = &stub;
        if (flags & MIdtor) *p++ = &stub;
        if (flags & MIictor) *p++ = &stub;
        *cast(size_t*)p++ = 0; // number of imported modules
        assert(cast(void*)p <= &mi + 1);
        return mi;
    }

    static void checkExp(string testname, bool shouldThrow,
        immutable(ModuleInfo*)[] modules,
        immutable(ModuleInfo*)[] dtors=null,
        immutable(ModuleInfo*)[] tlsdtors=null,
        size_t line=__LINE__)
    {
        printf("===== %.*s =====\n", cast(int)testname.length, testname.ptr);
        auto mgroup = ModuleGroup(modules);
        mgroup.sortCtors();

        // if we are expecting sort to throw, don't throw because of unexpected
        // success!
        if(!shouldThrow)
        {
            foreach (m; mgroup._modules)
                assert(!(m.flags & (MIctorstart | MIctordone)), testname);
            if (mgroup._ctors != dtors)
            {
                foreach (c; mgroup._ctors)
                    printf("%p,", c);
                printf(" : ");
                foreach (c; dtors)
                    printf("%p,", c);
                printf("\n");
            }
            import core.exception : onAssertErrorMsg;
            if (mgroup._ctors != dtors)
                onAssertErrorMsg(__FILE__, line, testname);
            if (mgroup._tlsctors != tlsdtors)
                onAssertErrorMsg(__FILE__, line, testname);
        }
    }

    {
        auto m0 = mockMI(0);
        auto m1 = mockMI(0);
        auto m2 = mockMI(0);
        checkExp("no ctors", false, [&m0.mi, &m1.mi, &m2.mi]);
    }

    {
        auto m0 = mockMI(MIictor);
        auto m1 = mockMI(0);
        auto m2 = mockMI(MIictor);
        auto mgroup = ModuleGroup([&m0.mi, &m1.mi, &m2.mi]);
        checkExp("independent ctors", false, [&m0.mi, &m1.mi, &m2.mi]);
    }

    {
        auto m0 = mockMI(MIstandalone | MIctor);
        auto m1 = mockMI(0);
        auto m2 = mockMI(0);
        auto mgroup = ModuleGroup([&m0.mi, &m1.mi, &m2.mi]);
        checkExp("standalone ctor", false, [&m0.mi, &m1.mi, &m2.mi], [&m0.mi]);
    }

    {
        auto m0 = mockMI(MIstandalone | MIctor);
        auto m1 = mockMI(MIstandalone | MIctor);
        auto m2 = mockMI(0);
        m1.setImports(&m0.mi);
        checkExp("imported standalone => no dependency", false, [&m0.mi, &m1.mi, &m2.mi], [&m0.mi, &m1.mi]);
    }

    {
        auto m0 = mockMI(MIstandalone | MIctor);
        auto m1 = mockMI(MIstandalone | MIctor);
        auto m2 = mockMI(0);
        m0.setImports(&m1.mi);
        checkExp("imported standalone => no dependency (2)", false, [&m0.mi, &m1.mi, &m2.mi], [&m1.mi, &m0.mi]);
    }

    {
        auto m0 = mockMI(MIstandalone | MIctor);
        auto m1 = mockMI(MIstandalone | MIctor);
        auto m2 = mockMI(0);
        m0.setImports(&m1.mi);
        m1.setImports(&m0.mi);
        checkExp("standalone may have cycle", false, [&m0.mi, &m1.mi, &m2.mi], [&m1.mi, &m0.mi]);
    }

    {
        auto m0 = mockMI(MIctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(0);
        m1.setImports(&m0.mi);
        checkExp("imported ctor => ordered ctors", false, [&m0.mi, &m1.mi, &m2.mi], [&m0.mi, &m1.mi], []);
    }

    {
        auto m0 = mockMI(MIctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(0);
        m0.setImports(&m1.mi);
        checkExp("imported ctor => ordered ctors (2)", false, [&m0.mi, &m1.mi, &m2.mi], [&m1.mi, &m0.mi], []);
    }

    {
        auto m0 = mockMI(MIctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(0);
        m0.setImports(&m1.mi);
        m1.setImports(&m0.mi);
        assertThrown!Throwable(checkExp("", true, [&m0.mi, &m1.mi, &m2.mi]), "detects ctors cycles");
    }

    {
        auto m0 = mockMI(MIctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(0);
        m0.setImports(&m2.mi);
        m1.setImports(&m2.mi);
        m2.setImports(&m0.mi, &m1.mi);
        assertThrown!Throwable(checkExp("", true, [&m0.mi, &m1.mi, &m2.mi]), "detects cycle with repeats");
    }

    {
        auto m0 = mockMI(MIctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(MItlsctor);
        m0.setImports(&m1.mi, &m2.mi);
        checkExp("imported ctor/tlsctor => ordered ctors/tlsctors", false, [&m0.mi, &m1.mi, &m2.mi], [&m1.mi, &m0.mi], [&m2.mi]);
    }

    {
        auto m0 = mockMI(MIctor | MItlsctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(MItlsctor);
        m0.setImports(&m1.mi, &m2.mi);
        checkExp("imported ctor/tlsctor => ordered ctors/tlsctors (2)", false, [&m0.mi, &m1.mi, &m2.mi], [&m1.mi, &m0.mi], [&m2.mi, &m0.mi]);
    }

    {
        auto m0 = mockMI(MIctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(MItlsctor);
        m0.setImports(&m1.mi, &m2.mi);
        m2.setImports(&m0.mi);
        checkExp("no cycle between ctors/tlsctors", false, [&m0.mi, &m1.mi, &m2.mi], [&m1.mi, &m0.mi], [&m2.mi]);
    }

    {
        auto m0 = mockMI(MItlsctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(MItlsctor);
        m0.setImports(&m2.mi);
        m2.setImports(&m0.mi);
        assertThrown!Throwable(checkExp("", true, [&m0.mi, &m1.mi, &m2.mi]), "detects tlsctors cycle");
    }

    {
        auto m0 = mockMI(MItlsctor);
        auto m1 = mockMI(MIctor);
        auto m2 = mockMI(MItlsctor);
        m0.setImports(&m1.mi);
        m1.setImports(&m0.mi, &m2.mi);
        m2.setImports(&m1.mi);
        assertThrown!Throwable(checkExp("", true, [&m0.mi, &m1.mi, &m2.mi]), "detects tlsctors cycle with repeats");
    }

    {
        auto m0 = mockMI(MIctor);
        auto m1 = mockMI(MIstandalone | MIctor);
        auto m2 = mockMI(MIstandalone | MIctor);
        m0.setImports(&m1.mi);
        m1.setImports(&m2.mi);
        m2.setImports(&m0.mi);
        // NOTE: this is implementation dependent, sorted order shouldn't be tested.
        //checkExp("closed ctors cycle", false, [&m0.mi, &m1.mi, &m2.mi], [&m1.mi, &m2.mi, &m0.mi]);
        checkExp("closed ctors cycle", false, [&m0.mi, &m1.mi, &m2.mi], [&m0.mi, &m1.mi, &m2.mi]);
    }
}

version (CRuntime_Microsoft)
{
    // Dummy so Win32 code can still call it
    extern(C) void _minit() { }
}
