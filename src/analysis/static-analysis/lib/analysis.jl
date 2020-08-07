#**********************************************************************
# Lightweight static analysis of eval/invokelatest
#**********************************************************************
# 
# 1) Reads files in [src] directory and counts the number of occurences
#    of "eval(", "@eval(", "@eval ", and "invokelatest("
#
# 2) For calls to eval, uses Julia parser to collect information about
#    AST heads of expressions passed to eval.
# 
#**********************************************************************

#--------------------------------------------------
# Imports
#--------------------------------------------------

# Just in case, we don't want to include code repeatedly
Core.isdefined(Main, :UTILS_DEFINED) ||
    include("../../../utils/lib.jl")
include("eval-parsing.jl")

import Base.show

###################################################
# Data
###################################################

#--------------------------------------------------
# Constants
#--------------------------------------------------

# Text-based analysis
#------------------------------

# regex-patterns for calls to eval/invokelatest
#   (\W means non-word character and ^ means beginning of input --
#    to exclude cases such as "my_eval(")
CALL_PATTERN(name :: String) = Regex("(\\W|^)$(name)\\(") # r"(\W|^)eval\("
const PATTERN_EVAL = CALL_PATTERN("eval")
const PATTERN_INVOKELATEST = CALL_PATTERN("invokelatest")
const PATTERN_EVAL_MACRO = r"@eval( |\()"

#--------------------------------------------------
# Data Types
#--------------------------------------------------

# Eval argument statistics
#------------------------------

# Frequency of eval arguments
EvalArgStat = Dict{EvalCallInfo, UInt}

# Overall statistics
#------------------------------

# Eval/invokelatest usage statistics
struct Stat
    eval         :: UInt # number of calls to eval
    invokelatest :: UInt # number of calls to invokelatest
    evalArgStat  :: EvalArgStat # stat of AST heads of evaled expressions
end
Stat() = Stat(0, 0, EvalArgStat())
Stat(ev :: Int, il :: Int) = Stat(ev, il, EvalArgStat())

# Files statistics (fileName => statistics)
FilesStat = Dict{String, Stat}

# Single package statistics
mutable struct PackageStat
    pkgName          :: String
    hasSrc           :: Bool
    totalFiles       :: UInt # number of source files
    failedFiles      :: UInt # number of files that failed to process
    interestingFiles :: UInt # number of files with eval/invokelatest
    filesStat        :: FilesStat # fileName => statistics
    pkgStat          :: Stat # package summary statistics
end
# default constructor
PackageStat(pkgName :: String, hasSrc :: Bool) = 
    PackageStat(pkgName, hasSrc, 0, 0, 0, FilesStat(), Stat())

# Summary of a set of packages
mutable struct PackagesTotalStat
    totalStat   :: Stat
    evalStat    :: EvalArgStat
    derivedStat :: Dict{String, Int}
end
PackagesTotalStat(ds :: Dict{String, Int}) =
    PackagesTotalStat(Stat(), EvalArgStat(), ds)

#--------------------------------------------------
# Show
#--------------------------------------------------

#Base.show(io :: IO, evalInfo :: EvalCallInfo) = print(io, evalInfo.astHead)

string10(x :: UInt) = string(x, base=10)

Base.show(io :: IO, un :: UInt) = print(io, string10(un))

Base.show(io :: IO, evStat :: EvalArgStat) = print(io, 
    "(" * 
    join(map(kv -> "$(kv[1]) => $(kv[2])", collect(pairs(evStat))), ", ") *
    ")")

Base.show(io :: IO, stat :: Stat) = print(io,
    "{ev: $(stat.eval), il: $(stat.invokelatest)}\n" *
    "  [evalArgs: $(stat.evalArgStat)]")

Base.show(io :: IO, stat :: FilesStat) = begin
    for info in stat
        println(io, "* $(info[1]) => $(info[2])")
    end
end

#--------------------------------------------------
# Stat Arithmetic
#--------------------------------------------------

Base.:+(x :: EvalArgStat, y :: EvalArgStat) = merge(+, x, y)

Base.zero(::Type{Stat}) = Stat()

Base.sum(stat :: Stat) :: UInt = stat.eval + stat.invokelatest

Base.:+(x :: Stat, y :: Stat) =
    Stat(x.eval + y.eval, x.invokelatest + y.invokelatest,
         x.evalArgStat + y.evalArgStat)

function incrementPkgsEvalStat!(
    totPkgsEvalStat :: EvalArgStat, evalStat :: EvalArgStat
) :: EvalArgStat
    for kv in evalStat
        if kv[2] > 0
            incrementDict!(totPkgsEvalStat, kv[1])
        end
    end
    totPkgsEvalStat
end

function addStats!(
    pts :: PackagesTotalStat, totalStat :: Stat, evalStat :: EvalArgStat
)
    pts.totalStat += totalStat;
    incrementPkgsEvalStat!(pts.evalStat, evalStat)
    pts
end

###################################################
# Algorithms
###################################################

#--------------------------------------------------
# Eval Arguments Statistics
#--------------------------------------------------

# AST → UInt
# Counts the number of calls to eval in [e]
# Note. It does not go into quote, e.g. inner eval in
#       [eval(:(eval(...)))] is ignored
countEval(e :: Expr) :: UInt =
    isEvalCall(e) ?
        1 : #(@show e ; 1) :
        sum(map(countEval, e.args))
countEval(@nospecialize e) :: UInt = 0

# AST → [Symbol] (Note that Symbol ~ EvalCallInfo at the moment)
# Collects information about eval call [e]
# assuming [e] IS an eval call (eval can be callen with no arguments)
getEvalInfo(e :: Expr, inFunDef::Bool=false) :: Vector{EvalCallInfo} = 
    length(e.args) > 1 ? 
        argDescr(e.args[end], inFunDef) : 
        [EvalCallInfo(:nothing, inFunDef)]

# AST → EvalCallsVec
# Collects information about arguments of all eval calls in [e]
gatherEvalInfo(e :: Expr, inFunDef::Bool=false) :: EvalCallsVec = begin
    #@info isFunDef(e) inFunDef
    isEvalCall(e) ?
        getEvalInfo(e, inFunDef) :
        foldl(
            vcat,
            # if [e] is fun definition, we will consider its subexpressions
            # to be inside function definition;
            # of course, this would mean that function parameters are also
            # inside function, but eval can't be used for parameters
            map(arg -> gatherEvalInfo(arg, inFunDef || isFunDef(e)), e.args);
            init=EvalCallInfo[]
        )
end
gatherEvalInfo(@nospecialize(e), inFunDef::Bool=false) :: EvalCallsVec =
    EvalCallInfo[]

#--------------------------------------------------
# Single File Statistics
#--------------------------------------------------

# Checks if statistics is not useless, i.e. there is at least one call
# to eval or invokelatest
nonVacuous(stat :: Stat) :: Bool = sum(stat) > 0
    #stat.invokelatest > 0

# Some measure of interest (we consider [stat] the most interesting
# if there are both eval and invokelatest calls)
interestFactor(stat :: Stat) :: UInt = let
    Z = zero(UInt)
    hasEval   = stat.eval > Z
    hasInvoke = stat.invokelatest > Z
    val = sum(stat)
    xor(hasEval, hasInvoke) ?
        val :
        (hasEval || hasInvoke ? 1000+val : Z)
end

# Computes eval/invokelatest statistics for source code [text]
# We use [filePath] for error reporting
function computeStat(text :: String, filePath :: String) :: Stat
    ev = count(PATTERN_EVAL, text) + count(PATTERN_EVAL_MACRO, text)
    il = count(PATTERN_INVOKELATEST, text)
    # get more details about eval if possible
    if ev > 0
        try
            evalInfos = gatherEvalInfo(parseJuliaCode(text))
            evArgStat = mkOccurDict(evalInfos)
            # parsing gives more precise results
            Stat(sum(values(evArgStat)), il, evArgStat)
        catch e
            @error filePath e
            Stat(ev, il, EvalArgStat(EvalCallInfo(:ERROR) => ev))
        end
    else
        Stat(ev, il)
    end
end

#--------------------------------------------------
# Single Package Statistics
#--------------------------------------------------

# String → Bool
isJuliaFile(fname :: String) :: Bool = endswith(fname, ".jl")

# String, PackageStat, String → Nothing
# Reads [filePath] located in [pkgPath]
#   and updates [pkgStat] accordingly with eval/invokelatest stats
function processFile(pkgPath::String, pkgStat::PackageStat, filePath::String)
    try
        stat = computeStat(read(filePath, String), filePath)
        #@info filePath stat
        if nonVacuous(stat)
            pkgStat.interestingFiles += 1
            # cut pkgPath from file name for readability
            pkgStat.filesStat[filePath[length(pkgPath)+1:end]] = stat
        end
    catch e
        println(stderr, e)
        pkgStat.failedFiles += 1
    end
end

# String, String → PackageStat
# Walks [src] directory of package [pkgName] located at [pkgPath]
# and collects eval/invokelatest statistics
function processPkg(pkgPath :: String, pkgName :: String) :: PackageStat
    # we assume that correct Julia packages have [src] folder
    srcPath = joinpath(pkgPath, "src")
    # init statistics
    pkgStat = PackageStat(pkgName, isdir(srcPath))
    pkgStat.hasSrc || return pkgStat # exit if no [src]
    # recursively walk all files in [src]
    for (root, _, files) in walkdir(srcPath)
        # we are only interested in Julia files
        files = filter(isJuliaFile, files)
        pkgStat.totalFiles += length(files)
        for file in files
            filePath = joinpath(root, file)
            processFile(pkgPath, pkgStat, filePath)
        end
    end
    # package summary statistics
    if pkgStat.interestingFiles > 0
        pkgStat.pkgStat = foldl(+, values(pkgStat.filesStat))
    end
    pkgStat
end

#--------------------------------------------------
# Packages
#--------------------------------------------------

isGoodPackage(pkgStat :: PackageStat) :: Bool = pkgStat.hasSrc

getInterestFactor(pkgStat :: PackageStat) :: UInt =
    interestFactor(pkgStat.pkgStat)

# String → Vector{PackageStat}, Vector{PackageStat}
# Processes every folder in [path] as a package folder
# and computes its statistics for it.
# Returns failed packages and stats for successfully processed packages
function processPkgsDir(path :: String)
    paths = map(name -> (joinpath(path, name), name), readdir(path))
    dirs  = filter(d -> isdir(d[1]), paths)
    pkgsStats = map(d -> processPkg(d[1], d[2]), dirs)
    goodPkgs  = filter(isGoodPackage,  pkgsStats)
    badPkgs   = filter(!isGoodPackage, pkgsStats)
    # sort packages information from most interesting to less interesting
    (badPkgs, sort(goodPkgs, by=getInterestFactor, rev=true))
end

###################################################
# Main
###################################################

#--------------------------------------------------
# Aux output
#--------------------------------------------------

function outputPkgsProcessingSummary(io :: IO,
    goodPkgsCnt, badPkgs :: Vector
)
    badPkgsCnt = length(badPkgs)
    totalCnt = goodPkgsCnt + badPkgsCnt
    println(io, "# processed package folders: $(totalCnt)")
    println(io, "# failed (no [src]): $(badPkgsCnt)/$(totalCnt)")
    badPkgsCnt == 0 ||
        for pkgInfo in badPkgs
            println(io, pkgInfo.pkgName)
        end
    println(io, "# successfully processed folders: $(goodPkgsCnt)\n")
    println(io, "==============================\n")
end

#--------------------------------------------------
# Computing derived metrics
#--------------------------------------------------

maybeInFunDefFunction(stat :: Stat) =
    !isempty(intersect(map(head -> EvalCallInfo(head, true),
        [SYM_FUNC, SYM_MCALL, :symbol, :expr, :parse, :include]),
        keys(stat.evalArgStat)
    ))

maybeInFunCallFunction(stat :: Stat) =
    !isempty(intersect(map(head -> EvalCallInfo(head, true),
        [SYM_CALL, SYM_MCALL, :(->), :symbol, :expr, :parse, :include]),
        keys(stat.evalArgStat)
    )) ||
    stat.invokelatest > 0

likelyInFunCallFunction(stat :: Stat) =
    in(EvalCallInfo(:call, true), keys(stat.evalArgStat)) ||
    stat.invokelatest > 0

likelyInFunCallFunctionButNotDef(stat :: Stat) =
    likelyInFunCallFunction(stat) && !maybeInFunDefFunction(stat)

maybeInFunDefFunButNotCall(stat :: Stat) =
    maybeInFunDefFunction(stat) && !likelyInFunCallFunction(stat)

allEvalsAreTopLevel(stat :: Stat) =
    all(evalInfo -> !evalInfo.inFunDef, keys(stat.evalArgStat))

allEvalsAreTopLevelAndNoIL(stat :: Stat) =
    all(evalInfo -> !evalInfo.inFunDef, keys(stat.evalArgStat)) &&
    stat.invokelatest == 0

singleTopLevelEvalAndNoIL(stat :: Stat) =
    stat.eval == 1 && !first(keys(stat.evalArgStat)).inFunDef &&
    stat.invokelatest == 0

const derivedConditions = Dict(
    "allEvalTop"        => allEvalsAreTopLevel,
    "allEvalTopNoIL"    => allEvalsAreTopLevelAndNoIL,
    "1TopEvalNoIL"      => singleTopLevelEvalAndNoIL,
    "fundef?"           => maybeInFunDefFunction,
    "onlyfundef?"       => maybeInFunDefFunButNotCall,
    "funcall?"          => maybeInFunCallFunction,
    "funcall!"          => likelyInFunCallFunction,
    "onlyfuncall!"      => likelyInFunCallFunctionButNotDef,
    "il"                => stat -> stat.invokelatest > 0
)

function computeDerivedMetrics(
    pkgInfos :: Vector{PackageStat}, io :: IO
) :: PackagesTotalStat
    pkgsStat :: PackagesTotalStat = PackagesTotalStat(
        Dict{String, Int}(map(param -> param=>0,
        ["non_vacuous", "allEvalTop", "allEvalTopNoIL", "1TopEvalNoIL",
         "fundef?", "onlyfundef?",
         "funcall?", "funcall!", "onlyfuncall!", "il"]))
    )
    for pkgInfo in pkgInfos
        # we don't output information about packages without eval/invokelatest
        pkgInfo.interestingFiles > 0 || continue
        println(io, "$(pkgInfo.pkgName): $(pkgInfo.pkgStat)")
        println(io, "# non vacuous files: $(pkgInfo.interestingFiles)/$(pkgInfo.totalFiles)")
        println(io, pkgInfo.filesStat)
        # compute summary stats
        pkgsStat.derivedStat["non_vacuous"] += 1
        addStats!(pkgsStat, pkgInfo.pkgStat, pkgInfo.pkgStat.evalArgStat)
        # ask more specific questions
        #maybeDefineFunction(pkgInfo.pkgStat) &&
        #    pkgsDerivedStat["fun_def"] += 1
        for propCond in derivedConditions
            if propCond[2](pkgInfo.pkgStat)
                pkgsStat.derivedStat[propCond[1]] += 1
            end
        end
    end
    pkgsStat
end

#--------------------------------------------------
# Running analysis on packages
#--------------------------------------------------

# Runs analysis on all packages from [pkgsDir]
function analyzePackages(pkgsDir :: String, io :: IO)
    isdir(pkgsDir) ||
        exitErrWithMsg("$(pkgsDir) must be a folder")
    # processing summary
    (badPkgs, goodPkgs) = processPkgsDir(pkgsDir)
    goodPkgsCnt = length(goodPkgs)
    outputPkgsProcessingSummary(io, goodPkgsCnt, badPkgs)
    # analyze all packages and summarize stats
    pkgsStat :: PackagesTotalStat = computeDerivedMetrics(goodPkgs, io)
    derivedStat = pkgsStat.derivedStat
    # output derived stats
    println(io, "==============================\n")
    println(io,
        "Non vacuous packages: $(derivedStat["non_vacuous"])/$(goodPkgsCnt)")
    println(io, "* all evals are top-level: $(derivedStat["allEvalTop"])/$(goodPkgsCnt)")
    println(io, "* all evals are top-level and no invokelatest: $(derivedStat["allEvalTopNoIL"])/$(goodPkgsCnt)")
    println(io, "* single top-level eval and no invokelatest: $(derivedStat["1TopEvalNoIL"])/$(goodPkgsCnt)")
    println(io, "* maybe function defs in fun: $(derivedStat["fundef?"])/$(goodPkgsCnt)")
    println(io, "* maybe function defs in fun but not likely calls: $(derivedStat["onlyfundef?"])/$(goodPkgsCnt)")
    println(io, "* maybe function calls in fun: $(derivedStat["funcall?"])/$(goodPkgsCnt)")
    println(io, "* likely function calls in fun: $(derivedStat["funcall!"])/$(goodPkgsCnt)")
    println(io, "* likely function calls in fun but not defs: $(derivedStat["onlyfuncall!"])/$(goodPkgsCnt)")
    println(io, "* invokelatest: $(derivedStat["il"])/$(goodPkgsCnt)")
    println(io)
    println(io, "Total Stat:")
    for info in sort(collect(pkgsStat.totalStat.evalArgStat);
                     by=kv->kv[2], rev=true)
        println(io,
            "* $(rpad(info[1].astHead, 10)) $(showEvalLevel(info[1].inFunDef))" *
            " => $(lpad(info[2], 4))" *
            " in $(lpad(pkgsStat.evalStat[info[1]], 3)) pkgs")
    end
    println(io)
end


