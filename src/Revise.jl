module Revise

using FileWatching, REPL, Distributed, UUIDs
import LibGit2
using Base: PkgId

using OrderedCollections: OrderedDict

export revise, includet, MethodSummary

"""
    Revise.watching_files[]

Returns `true` if we watch files rather than their containing directory.
FreeBSD and NFS-mounted systems should watch files, otherwise we prefer to watch
directories.
"""
const watching_files = Ref(Sys.KERNEL == :FreeBSD)

"""
    Revise.polling_files[]

Returns `true` if we should poll the filesystem for changes to the files that define
loaded code. It is preferable to avoid polling, instead relying on operating system
notifications via `FileWatching.watch_file`. However, NFS-mounted
filesystems (and perhaps others) do not support file-watching, so for code stored
on such filesystems you should turn polling on.

See the documentation for the `JULIA_REVISE_POLL` environment variable.
"""
const polling_files = Ref(false)
function wait_changed(file)
    try
        polling_files[] ? poll_file(file) : watch_file(file)
    catch err
        if Sys.islinux() && err isa SystemError && err.errnum == 28  # ENOSPC
            @warn """Your operating system has run out of inotify capacity.
            Check the current value with `cat /proc/sys/fs/inotify/max_user_watches`.
            Set it to a higher level with, e.g., `echo 65536 | sudo tee -a /proc/sys/fs/inotify/max_user_watches`.
            This requires having administrative privileges on your machine (or talk to your sysadmin).
            See https://github.com/timholy/Revise.jl/issues/26 for more information."""
        end
        rethrow(err)
    end
    return nothing
end

"""
    Revise.tracking_Main_includes[]

Returns `true` if files directly included from the REPL should be tracked.
The default is `false`. See the documentation regarding the `JULIA_REVISE_INCLUDE`
environment variable to customize it.
"""
const tracking_Main_includes = Ref(false)

include("relocatable_exprs.jl")
include("types.jl")
include("parsing.jl")
include("exprutils.jl")
include("pkgs.jl")
include("git.jl")
include("recipes.jl")
include("logging.jl")

### Globals to keep track of state

"""
    Revise.watched_files

Global variable, `watched_files[dirname]` returns the collection of files in `dirname`
that we're monitoring for changes. The returned value has type [`WatchList`](@ref).

This variable allows us to watch directories rather than files, reducing the burden on
the OS.
"""
const watched_files = Dict{String,WatchList}()

"""
    Revise.revision_queue

Global variable, `revision_queue` holds the names of files that we need to revise, meaning
that these files have changed since we last processed a revision.
This list gets populated by callbacks that watch directories for updates.
"""
const revision_queue = Set{String}()

"""
    Revise.fileinfos

`fileinfos` is the core information that tracks the relationship between source code
and julia objects, and allows re-evaluation of code in the proper module scope.
It is a dictionary indexed by absolute paths of files;
`fileinfos[filename]` returns a value of type [`Revise.FileInfo`](@ref).
"""
const fileinfos = Dict{String,FileInfo}()

"""
    Revise.module2files

`module2files` holds the list of filenames used to define a particular
module. This is only used by `revise(MyModule)` to "refresh" all the definitions in a module.
"""
const module2files = Dict{Symbol,Vector{String}}()

"""
    Revise.included_files

Global variable, `included_files` gets populated by callbacks we register with `include`.
It's used to track non-precompiled packages and, optionally, user scripts (see docs on
`JULIA_REVISE_INCLUDE`).
"""
const included_files = Tuple{Module,String}[]  # (module, filename)

"""
    Revise.basesrccache

Full path to the running Julia's cache of source code defining `Base`.
"""
const basesrccache = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base.cache")

"""
    Revise.basebuilddir

Julia's top-level directory when Julia was built, as recorded by the entries in
`Base._included_files`.
"""
const basebuilddir = begin
    sysimg = filter(x->endswith(x[2], "sysimg.jl"), Base._included_files)[1][2]
    dirname(dirname(sysimg))
end

"""
    Revise.juliadir

Constant specifying full path to julia top-level source directory.
This should be reliable even for local builds, cross-builds, and binary installs.
"""
const juliadir = begin
    local jldir = basebuilddir
    if !isdir(joinpath(jldir, "base"))
        # Binaries probably end up here. We fall back on Sys.BINDIR
        jldir = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
        if !isdir(joinpath(jldir, "base"))
            while true
                trydir = joinpath(jldir, "base")
                isdir(trydir) && break
                trydir = joinpath(jldir, "share", "julia", "base")
                if isdir(trydir)
                    jldir = joinpath(jldir, "share", "julia")
                    break
                end
                jldirnext = dirname(jldir)
                jldirnext == jldir && break
                jldir = jldirnext
            end
        end
    end
    jldir
end
const cache_file_key = Dict{String,String}() # corrected=>uncorrected filenames

"""
    Revise.dont_watch_pkgs

Global variable, use `push!(Revise.dont_watch_pkgs, :MyPackage)` to prevent Revise
from tracking changes to `MyPackage`. You can do this from the REPL or from your
`.julia/config/startup.jl` file.

See also [`Revise.silence`](@ref).
"""
const dont_watch_pkgs = Set{Symbol}()
const silence_pkgs = Set{Symbol}()
const depsdir = joinpath(dirname(@__DIR__), "deps")
const silencefile = Ref(joinpath(depsdir, "silence.txt"))  # Ref so that tests don't clobber

function use_compiled_modules()
    return Base.JLOptions().use_compiled_modules != 0
end



"""
    fmrep = eval_revised(fmnew::FileModules, fmref::FileModules)

Implement the changes from `fmref` to `fmnew`, returning a replacement [`FileModules`](@ref)
`fmrep`.
"""
function eval_revised(fmnew::FileModules, fmref::FileModules)
    fmrep = FileModules(first(keys(fmref)))  # replacement for fmref
    for (mod, fmmnew) in fmnew
        fmrep[mod] = fmm = FMMaps()
        if haskey(fmref, mod)
            eval_revised!(fmm, mod, fmmnew, fmref[mod])
            for p in workers()
                p == myid() && continue
                remotecall(eval_revised_dummy!, p, mod, fmmnew, fmref[mod])
            end
        else  # a new submodule (see #43)
            eval_and_insert_all!(fmm, mod, fmmnew.defmap)
            for p in workers()
                p == myid() && continue
                remotecall(eval_and_insert_all_dummy!, p, mod, fmmnew.defmap)
            end
        end
    end
    fmrep
end

function eval_revised!(fmmrep::FMMaps, mod::Module,
                       fmmnew::FMMaps, fmmref::FMMaps)
    # Update to the state of fmmnew, preventing any unnecessary evaluation
    with_logger(_debug_logger) do
        @debug "Diff" _group="Parsing" activemodule=fullname(mod) newexprs=setdiff(keys(fmmnew.defmap), keys(fmmref.defmap)) oldexprs=setdiff(keys(fmmref.defmap), keys(fmmnew.defmap))
        # Delete any methods missing in fmmnew
        # Because we haven't yet evaled and gotten signature types, let's do this "from scratch" using method signatures.
        # (It might be more efficient to eval first and delete later, but this proves to be safer.)
        oldsigs, newsigs = filter_signatures(mod, keys(fmmref.defmap)), filter_signatures(mod, keys(fmmnew.defmap))
        for sig in oldsigs
            sig ∈ newsigs && continue
            @debug "DiffSig" _group="Parsing" activemodule=fullname(mod) missingsig=sig newsigs=newsigs
            for sigt in sigex2sigts(mod, sig)
                m = get_method(sigt)
                if isa(m, Method)
                    Base.delete_method(m)
                    @debug "DeleteMethod" _group="Action" time=time() deltainfo=(sigt, MethodSummary(m))
                else
                    mths = Base._methods_by_ftype(sigt, -1, typemax(UInt))
                    io = IOBuffer()
                    println(io, "Extracted method table:")
                    println(io, mths)
                    info = String(take!(io))
                    @warn "Revise failed to find any methods for signature $sigt\n  Perhaps it was already deleted.\n$info"
                end
            end
        end
        # Eval any expressions unique to fmmnew
        for (def,val) in fmmnew.defmap
            @assert def != nothing
            defref = getkey(fmmref.defmap, def, nothing)
            if defref != nothing
                # The same expression is found in both, only update the lineoffset
                if val !== nothing
                    sigtref, oldoffset = fmmref.defmap[defref]
                    lnref = firstlineno(defref)
                    lnnew = firstlineno(def)
                    lineoffset = (isa(lnref, Integer) && isa(lnnew, Integer)) ? lnnew-lnref : 0
                    fmmrep.defmap[defref] = (sigtref, lineoffset)
                    for sigt in sigtref
                        # sigt = sigt2methsig(sigt)
                        fmmrep.sigtmap[sigt] = defref
                    end
                    oldoffset != lineoffset && @debug "LineOffset" _group="Action" time=time() deltainfo=(sigtref, lnnew, oldoffset=>lineoffset)
                else
                    fmmrep.defmap[defref] = nothing
                end
            else
                eval_and_insert!(fmmrep, mod, def=>val)
            end
        end
    end
    return fmmrep
end

function filter_signatures(mod::Module, defs)
    sigs = Set{RelocatableExpr}()
    for def in defs
        while is_trivial_block_wrapper(def)
            def = def.args[end]
        end
        def isa ExLike || continue
        if def.head == :macrocall
            _, def = macexpand(mod, convert(Expr, def))
            def isa ExLike || continue
        end
        def.head == :function || def.head == :(=) || continue
        sig = get_signature(def)
        sig isa ExLike || continue
        push!(sigs, relocatable!(sig))
    end
    return sigs
end

eval_revised_dummy!(mod::Module, fmmnew::FMMaps, fmmref::FMMaps) =
    eval_revised!(FMMaps(), mod, fmmnew, fmmref)

function eval_and_insert!(fmm::FMMaps, mod::Module, pr::Pair)
    def, val = pr.first, pr.second
    ex = convert(Expr, def)
    try
        if isdocexpr(ex) && mod == Base.__toplevel__
            Core.eval(Main, ex)
        else
            Core.eval(mod, ex)
        end
        @debug "Eval" _group="Action" time=time() deltainfo=(mod, relocatable!(ex))
        if val isa RelocatableExpr
            instantiate_sigs!(fmm, def, val, mod)
        else
            if val !== nothing
                sigts = Any[sigt2methsig(sigt) for sigt in val[1]]
                fmm.defmap[def] = (sigts, val[2])
                for sigt in sigts
                    fmm.sigtmap[sigt] = def
                end
            else
                fmm.defmap[def] = val
            end
        end
    catch err
        @error "failure to evaluate changes in $mod"
        showerror(stderr, err)
        println_maxsize(stderr, "\n", ex; maxlines=20)
    end
    return fmm
end

function eval_and_insert_all!(fmm::FMMaps, mod::Module, defmap::DefMap)
    for pr in defmap
        eval_and_insert!(fmm, mod, pr)
    end
end

eval_and_insert_all_dummy!(mod::Module, defmap::DefMap) =
    eval_and_insert_all!(FMMaps(), mod, defmap)

"""
    Revise.init_watching(files)

For every filename in `files`, monitor the filesystem for updates. When the file is
updated, either [`revise_dir_queued`](@ref) or [`revise_file_queued`](@ref) will
be called.
"""
function init_watching(files)
    udirs = Set{String}()
    for file in files
        dir, basename = splitdir(file)
        haskey(watched_files, dir) || (watched_files[dir] = WatchList())
        push!(watched_files[dir], basename)
        if watching_files[]
            @async revise_file_queued(file)
        else
            push!(udirs, dir)
        end
    end
    for dir in udirs
        updatetime!(watched_files[dir])
        @async revise_dir_queued(dir)
    end
    return nothing
end

"""
    revise_dir_queued(dirname)

Wait for one or more of the files registered in `Revise.watched_files[dirname]` to be
modified, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called within an `@async`.
"""
@noinline function revise_dir_queued(dirname)
    if !isdir(dirname)
        sleep(0.1)   # in case git has done a delete/replace cycle
        if !isfile(dirname)
            with_logger(SimpleLogger(stderr)) do
                @warn "$dirname is not an existing directory, Revise is not watching"
            end
            return nothing
        end
    end
    latestfiles = watch_files_via_dir(dirname)  # will block here until file(s) change
    for file in latestfiles
        push!(revision_queue, file)
    end
    @async revise_dir_queued(dirname)
end

# See #66.
"""
    revise_file_queued(filename)

Wait for modifications to `filename`, and then queue the corresponding files on [`Revise.revision_queue`](@ref).
This is generally called within an `@async`.

This is used only on platforms (like BSD) which cannot use [`revise_dir_queued`](@ref).
"""
function revise_file_queued(file)
    if !isfile(file)
        sleep(0.1)  # in case git has done a delete/replace cycle
        if !isfile(file)
            with_logger(SimpleLogger(stderr)) do
                @error "$file is not an existing file, Revise is not watching"
            end
            return nothing
        end
    end

    wait_changed(file)  # will block here until the file changes
    push!(revision_queue, file)
    @async revise_file_queued(file)
end

"""
    Revise.revise_file_now(file)

Process revisions to `file`. This parses `file` and computes an expression-level diff
between the current state of the file and its most recently evaluated state.
It then deletes any removed methods and re-evaluates any changed expressions.

`file` must be a key in [`Revise.fileinfos`](@ref)
"""
function revise_file_now(file)
    if !haskey(fileinfos, file)
        println("Revise is currently tracking the following files: ", keys(fileinfos))
        error(file, " is not currently being tracked.")
    end
    fi = fileinfos[file]
    maybe_parse_from_cache!(fi, file)
    fmref = fi.fm
    topmod = first(keys(fi.fm))
    fmnew = parse_source(file, topmod)
    if fmnew != nothing
        fmrep = eval_revised(fmnew, fmref)
        fileinfos[file] = FileInfo(fmrep, fi)
    end
    nothing
end

function instantiate_sigs!(fm::FileModules)
    for (mod, fmm) in fm
        instantiate_sigs!(fmm, mod)
    end
    return fm
end

function instantiate_sigs!(fmm::FMMaps, mod::Module)
    for (def, sig) in fmm.defmap
        if sig isa RelocatableExpr
            instantiate_sigs!(fmm, def, sig, mod)
        end
    end
    return fmm
end

function instantiate_sigs!(fmm::FMMaps, def::RelocatableExpr, sig::RelocatableExpr, mod::Module)
    sigts = sigex2sigts(mod, sig, def)
    sigts = Any[sigt2methsig(sigt) for sigt in sigts]
    # Insert into the maps
    fmm.defmap[def] = (sigts, 0)
    for sigt in sigts
        fmm.sigtmap[sigt] = def
    end
    return def
end

"""
    revise()

`eval` any changes in the revision queue. See [`Revise.revision_queue`](@ref).
"""
function revise()
    sleep(0.01)  # in case the file system isn't quite done writing out the new files
    for file in revision_queue
        revise_file_now(file)
    end
    empty!(revision_queue)
    tracking_Main_includes[] && queue_includes(Main)
    nothing
end

# This variant avoids unhandled task failures
function revise(backend::REPL.REPLBackend)
    sleep(0.01)  # in case the file system isn't quite done writing out the new files
    for file in revision_queue
        try
            revise_file_now(file)
        catch err
            put!(backend.response_channel, (err, catch_backtrace()))
        end
    end
    empty!(revision_queue)
    tracking_Main_includes[] && queue_includes(Main)
    nothing
end

"""
    revise(mod::Module)

Reevaluate every definition in `mod`, whether it was changed or not. This is useful
to propagate an updated macro definition, or to force recompiling generated functions.
"""
function revise(mod::Module)
    for file in module2files[Symbol(mod)]
        for (mod,fmm) in fileinfos[file].fm
            for def in keys(fmm.defmap)
                Core.eval(mod, convert(Expr, def))
            end
        end
    end
    return true  # fixme try/catch?
end

"""
    Revise.track(mod::Module, file::AbstractString)
    Revise.track(file::AbstractString)

Watch `file` for updates and [`revise`](@ref) loaded code with any
changes. `mod` is the module into which `file` is evaluated; if omitted,
it defaults to `Main`.
"""
function track(mod::Module, file::AbstractString)
    isfile(file) || error(file, " is not a file")
    file = normpath(abspath(file))
    fm = parse_source(file, mod)
    if fm != nothing
        instantiate_sigs!(fm)
        fileinfos[file] = FileInfo(fm)
    end
    init_watching((file,))
end

track(file::AbstractString) = track(Main, file)

"""
    includet(filename)

Load `filename` and track any future changes to it.
`includet` is deliberately non-recursive, so if `filename` loads any other files,
they will not be automatically tracked.
(See [`Revise.track`](@ref) to set it up manually.)

`includet` is intended for "user scripts," e.g., a file you use locally for a specific
purpose such as loading a specific data set or performing some kind of analysis.
Do not use `includet` for packages, as those should be handled by `using` or `import`.
If `using` and `import` aren't working, you may have packages in a non-standard location;
try fixing it with something like `push!(LOAD_PATH, "/path/to/my/private/repos")`.
"""
includet(file::AbstractString) = (Base.include(Main, file); track(Main, file))

"""
    Revise.silence(pkg)

Silence warnings about not tracking changes to package `pkg`.
"""
function silence(pkg::Symbol)
    push!(silence_pkgs, pkg)
    if !isdir(depsdir)
        mkpath(depsdir)
    end
    open(silencefile[], "w") do io
        for p in silence_pkgs
            println(io, p)
        end
    end
    nothing
end
silence(pkg::AbstractString) = silence(Symbol(pkg))

## Utilities

"""
    method = get_method(sigt)

Get the method `method` with signature-type `sigt`. This is used to provide
the method to `Base.delete_method`. See also [`get_signature`](@ref).

If `sigt` does not correspond to a method, returns `nothing`.

# Examples

```jldoctest; setup = :(using Revise), filter = r"in Main at.*"
julia> mymethod(::Int) = 1
mymethod (generic function with 1 method)

julia> mymethod(::AbstractFloat) = 2
mymethod (generic function with 2 methods)

julia> Revise.get_method(Tuple{typeof(mymethod), Int})
mymethod(::Int64) in Main at REPL[0]:1

julia> Revise.get_method(Tuple{typeof(mymethod), Float64})
mymethod(::AbstractFloat) in Main at REPL[1]:1

julia> Revise.get_method(Tuple{typeof(mymethod), Number})

```
"""
function get_method(@nospecialize(sigt))
    mths = Base._methods_by_ftype(sigt, -1, typemax(UInt))
    length(mths) == 1 && return mths[1][3]
    if !isempty(mths)
        # There might be many methods, but the one that should match should be the
        # last one, since methods are ordered by specificity
        i = lastindex(mths)
        while i > 0
            m = mths[i][3]
            m.sig == sigt && return m
            i -= 1
        end
    end
    return nothing
end

"""
    rex = get_def(method::Method)

Return the RelocatableExpr defining `method`.
The source-file defining `method` must be tracked.
If it is in Base, this will execute `track(Base)` if necessary.
"""
function get_def(method::Method; modified_files=revision_queue)
    filename = String(method.file)
    yield()   # magic bug fix for the OSX test failures. TODO: figure out why this works (prob. Julia bug)
    startswith(filename, "REPL") && error("methods defined at the REPL are not yet supported")
    # First we check for whether `filename` is consistent with the module.
    # If not, most likely this is a method that was defined via a macro defined in a different module.
    # E.g., https://github.com/timholy/Rebugger.jl/issues/3
    modfiles = get(module2files, nameof(method.module), nothing)
    if modfiles != nothing && filename ∉ modfiles
        # Try to find the actual file
        for file in modfiles
            fi = fileinfos[file]
            maybe_parse_from_cache!(fi, file)
            haskey(fi.fm, method.module) || continue
            map = fi.fm[method.module].sigtmap
            def = get(map, method.sig, nothing)
            def == nothing || return copy(def)
        end
    end
    recipemod = method.module
    if !haskey(fileinfos, filename)
        ret = find_file(filename, recipemod)
        if ret == nothing
            @warn "file $filename is not tracked by Revise"
            return nothing
        end
        filename, recipemod = ret
    end
    filename isa AbstractString || return nothing
    if !haskey(fileinfos, filename)
        @info "tracking $recipemod"
        track(recipemod; modified_files=modified_files)
    end
    fi = fileinfos[filename]
    maybe_parse_from_cache!(fi, filename)
    map = fi.fm[method.module].sigtmap
    haskey(map, method.sig) && return copy(map[method.sig])
    @warn "$(method.sig) was not found, perhaps it was generated by code"
    nothing
end

function find_file(filename, mod)
    # For files not in fileinfos, see if we can identify their origin in Base or the stdlibs
    handledmods = (Base, Core.Compiler)
    newmod = parentmodule(mod)
    while mod ∉ handledmods && newmod != mod
        mod = newmod
        newmod = parentmodule(mod)
    end
    if mod ∈ handledmods
        basefile = Base.find_source_file(filename)  # check base
        basefile isa AbstractString && return fixpath(realpath(basefile)), mod
    elseif occursin("stdlib", filename)
        return fixpath(realpath(filename)), mod
    end
    return nothing
end

function printf_maxsize(f::Function, io::IO, args...; maxchars::Integer=500, maxlines::Integer=20)
    # This is dumb but certain to work
    iotmp = IOBuffer()
    for a in args
        print(iotmp, a)
    end
    print(iotmp, '\n')
    seek(iotmp, 0)
    str = read(iotmp, String)
    if length(str) > maxchars
        str = first(str, (maxchars+1)÷2) * "…" * last(str, maxchars - (maxchars+1)÷2)
    end
    lines = split(str, '\n')
    if length(lines) <= maxlines
        for line in lines
            f(io, line)
        end
        return
    end
    half = (maxlines+1) ÷ 2
    for i = 1:half
        f(io, lines[i])
    end
    maxlines > 1 && f(io, ⋮)
    for i = length(lines) - (maxlines-half) + 1:length(lines)
        f(io, lines[i])
    end
end
println_maxsize(args...; kwargs...) = println_maxsize(stdout, args...; kwargs...)
println_maxsize(io::IO, args...; kwargs...) = printf_maxsize(println, stdout, args...; kwargs...)

function fix_line_statements!(ex::Expr, file::Symbol, line_offset::Int=0)
    if ex.head == :line
        ex.args[1] += line_offset
        ex.args[2] = file
    else
        for (i, a) in enumerate(ex.args)
            if isa(a, Expr)
                fix_line_statements!(a::Expr, file, line_offset)
            elseif isa(a, LineNumberNode)
                ex.args[i] = file_line_statement(a::LineNumberNode, file, line_offset)
            end
        end
    end
    ex
end

file_line_statement(lnn::LineNumberNode, file::Symbol, line_offset) =
    LineNumberNode(lnn.line + line_offset, file)

function update_stacktrace_lineno!(trace)
    for i = 1:length(trace)
        t, n = trace[i]
        if t.linfo isa Core.MethodInstance
            sigt = t.linfo.def.sig
            file = String(t.file)
            if haskey(fileinfos, file)
                fm = fileinfos[file].fm
                for (mod, fmm) in fm
                    if haskey(fmm.sigtmap, sigt)
                        def = fmm.sigtmap[sigt]
                        lineoffset = fmm.defmap[def][2]
                        if lineoffset != 0
                            t = StackTraces.StackFrame(t.func, t.file, t.line+lineoffset, t.linfo, t.from_c, t.inlined, t.pointer)
                            trace[i] = (t, n)
                            break
                        end
                    end
                end
            end
        end
    end
    return trace
end

function macroreplace!(ex::Expr, filename)
    for i = 1:length(ex.args)
        ex.args[i] = macroreplace!(ex.args[i], filename)
    end
    if ex.head == :macrocall
        m = ex.args[1]
        if m == Symbol("@__FILE__")
            return String(filename)
        elseif m == Symbol("@__DIR__")
            return dirname(String(filename))
        end
    end
    return ex
end
macroreplace!(s, filename) = s

@noinline function run_backend(backend)
    while true
        tls = task_local_storage()
        tls[:SOURCE_PATH] = nothing
        ast, show_value = take!(backend.repl_channel)
        if show_value == -1
            # exit flag
            break
        end
        # Process revisions
        revise(backend)
        # Now eval the input
        REPL.eval_user_input(ast, backend)
    end
    nothing
end

"""
    steal_repl_backend(backend = Base.active_repl_backend)

Replace the REPL's normal backend with one that calls [`revise`](@ref) before executing
any REPL input.
"""
function steal_repl_backend(backend = Base.active_repl_backend)
    @async begin
        # terminate the current backend
        put!(backend.repl_channel, (nothing, -1))
        fetch(backend.backend_task)
        # restart a new backend that differs only by processing the
        # revision queue before evaluating each user input
        backend.backend_task = @async run_backend(backend)
    end
    nothing
end

function wait_steal_repl_backend()
    iter = 0
    # wait for active_repl_backend to exist
    while !isdefined(Base, :active_repl_backend) && iter < 20
        sleep(0.05)
        iter += 1
    end
    if isdefined(Base, :active_repl_backend)
        steal_repl_backend(Base.active_repl_backend)
    else
        @warn "REPL initialization failed, Revise is not in automatic mode. Call `revise()` manually."
    end
end

"""
    Revise.async_steal_repl_backend()

Wait for the REPL to complete its initialization, and then call [`steal_repl_backend`](@ref).
This is necessary because code registered with `atreplinit` runs before the REPL is
initialized, and there is no corresponding way to register code to run after it is complete.
"""
function async_steal_repl_backend()
    mode = get(ENV, "JULIA_REVISE", "auto")
    if mode == "auto"
        atreplinit() do repl
            @async wait_steal_repl_backend()
        end
    end
    return nothing
end

function __init__()
    # Base.register_root_module(Base.__toplevel__)
    if isfile(silencefile[])
        pkgs = readlines(silencefile[])
        for pkg in pkgs
            push!(silence_pkgs, Symbol(pkg))
        end
    end
    push!(Base.package_callbacks, watch_package)
    push!(Base.include_callbacks,
        (mod::Module, fn::AbstractString) -> push!(included_files, (mod, normpath(abspath(fn)))))
    mode = get(ENV, "JULIA_REVISE", "auto")
    if mode == "auto"
        if isdefined(Base, :active_repl_backend)
            steal_repl_backend(Base.active_repl_backend)
        elseif isdefined(Main, :IJulia)
            Main.IJulia.push_preexecute_hook(revise)
        end
        if isdefined(Main, :Atom)
            for x in ["eval", "evalall", "evalrepl"]
                old = Main.Atom.handlers[x]
                Main.Atom.handle(x) do data
                    revise()
                    old(data)
                end
            end
        end
    end
    polling = get(ENV, "JULIA_REVISE_POLL", "0")
    if polling == "1"
        polling_files[] = watching_files[] = true
    end
    rev_include = get(ENV, "JULIA_REVISE_INCLUDE", "0")
    if rev_include == "1"
        tracking_Main_includes[] = true
    end
    # Correct line numbers for code moving around
    Base.update_stackframes_callback[] = update_stacktrace_lineno!
end

## WatchList utilities
function systime()
    tv = Libc.TimeVal()
    tv.sec + tv.usec/10^6
end
function updatetime!(wl::WatchList)
    wl.timestamp = systime()
end
Base.push!(wl::WatchList, filename) = push!(wl.trackedfiles, filename)
WatchList() = WatchList(systime(), Set{String}())
Base.in(file, wl::WatchList) = in(file, wl.trackedfiles)

include("precompile.jl")
_precompile_()

end # module
