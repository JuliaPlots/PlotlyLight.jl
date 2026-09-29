#------------------------------------------------------------------------------# json
# All serialization to JSON goes through `json(io, x)`

function json_join(io::IO, itr, left, right, f=json)
    print(io, left)
    for (i, item) in enumerate(itr)
        i == 1 || print(io, ',')
        f(io, item)
    end
    print(io, right)
end

struct RawJS
    code::String
end
json(io::IO, x::RawJS) = print(io, x.code)

json(x) = sprint(json, x)

# Fallback `json` method.  Iterables are Arrays, everything else is an error.
function json(io::IO, x)
    applicable(iterate, x) || throw(unsupported(x))
    json_join(io, x, '[', ']')
end

unsupported(x) = ArgumentError("""
    PlotlyLight doesn't know how to write a `$(typeof(x))` as JSON.  Convert it to a supported type,
    or add a method: `PlotlyLight.json(io::IO, x::$(typeof(x))) = <write x's JSON to io>`
    """)

# Strings: JSON escapes ('"', '\\', control chars), plus `<`, `>`, and `&`
function json(io::IO, str::AbstractString)
    print(io, '"')
    foreach(c -> print(io, get(JSON_ESCAPES, c, c)), str)
    print(io, '"')
end

const JSON_ESCAPES = Dict(
    (Char(b) => "\\u" * string(b; base=16, pad=4) for b in 0x00:0x1f)...,
    (c => escape_string(string(c)) for c in "\n\r\t\"\\")...,
    '<' => "\\u003c", '>' => "\\u003e", '&' => "\\u0026",
)

json(io::IO, x::Union{AbstractChar, Symbol, Dates.TimeType}) = json(io, string(x))

# Numbers: Integers (and Bools) as-is, other Reals (Rational, etc.) as floats, and NaN/±Inf as null.  Whole numbers
# that fit in an Int64 drop the `.0` (it's the same number in JS); larger ones stay floats, e.g. `1.0e20`.
json(io::IO, x::Number) = throw(unsupported(x))
function json(io::IO, x::Real)
    isinteger(x) && typemin(Int64) <= x <= typemax(Int64) && return print(io, Int64(x))
    y = float(x)
    isfinite(y) ? print(io, y) : print(io, "null")
end
json(io::IO, x::Integer) = print(io, x)
json(io::IO, ::Union{Missing, Nothing}) = print(io, "null")

# Arrays: a matrix is an array of rows
json(io::IO, x::AbstractVector) = json_join(io, x, '[', ']')
json(io::IO, x::AbstractArray) = json_join(io, eachslice(x; dims=1), '[', ']')
json(io::IO, x::AbstractArray{<:Any, 0}) = json(io, x[])

# Objects: keys are written as strings, and a Pair is an object with one key
json(io::IO, x::Union{AbstractDict, NamedTuple}) = json_join(io, pairs(x), '{', '}', json_member)
json(io::IO, x::Pair) = json_join(io, (x,), '{', '}', json_member)
json_member(io::IO, (k, v)) = (json(io, string(k)); print(io, ':'); json(io, v))


#------------------------------------------------------------------------------# TypedArray
# Plotly.js has a "TypedArraySpec": { bdata, dtype, ?shape } for base64-encoded typed arrays

const INT_DTYPES = (UInt8, Int8, UInt16, Int16, UInt32, Int32)
const FLOAT_DTYPES = (Float32, Float64)  # Float16 not yet supported by TypedArraySpec
const DTYPES = (INT_DTYPES..., FLOAT_DTYPES...)
const JS_ARRAYS = Dict(
    (T => string(titlecase(string(T)), "Array") for T in DTYPES)...,
    Float16 => "Float16Array"  # Not supported through TypedArraySpec
)

# Can type `T` represent number `x` (within acceptable error tolerances)?
_fits(T, x; rtol=0.0, atol=0.0, nans=true) = isapprox(Float64(x), T(x); rtol, atol, nans)

# Smallest DTYPE that can represent every value in `x`, or `nothing` if plotly.js can't decode `x` as a typed array
function min_type(x::AbstractArray; rtol=0.0, atol=0.0)
    (isempty(x) || ndims(x) > 3 || !(eltype(x) <: Real) || eltype(x) <: Bool) && return nothing
    if all(isinteger, x)  # isinteger implies isfinite
        (a, b) = extrema(x)
        i = findfirst(T -> typemin(T) ≤ a && b ≤ typemax(T), INT_DTYPES)
        isnothing(i) || return INT_DTYPES[i]
    end
    i = findfirst(T -> all(v -> _fits(T, v; rtol, atol), x), FLOAT_DTYPES)
    FLOAT_DTYPES[i]
end

_rowmajor(x) = permutedims(x, ndims(x):-1:1)  # plotly.js reads arrays row-major
_bdata(x) = base64encode(_rowmajor(x))
_dtype(x) = lowercase(string(eltype(x)))
_shape(x) = join(size(x), ',')

# plotly.js TypedArraySpec for `x`, or `x` itself if plotly.js can't decode it as a typed array
function typed_array(x; rtol=0.0, atol=0.0)
    T = min_type(x; rtol, atol)
    isnothing(T) && return x
    y = eltype(x) == T ? x : T.(x)
    (; bdata=_bdata(y), dtype=_dtype(y), shape=_shape(y))
end

# In case you want the Plot object to keep your original data
struct TypedArray
    x::AbstractArray
    rtol::Float64
    atol::Float64
    TypedArray(x, rtol=0.0, atol=0.0) = new(x, rtol, atol)
end

json(io::IO, o::TypedArray) = json(io, typed_array(o.x; o.rtol, o.atol))

#------------------------------------------------------------------------------# Compressed
# Number arrays:
# bytes -> zlib -> base64 -> DecompressionStream("deflate") -> ArrayBuffer -> JSArray -> reshape

# Fallback for everything else:
# json string -> zlib -> base64 -> DecompressionStream -> Response.json()

# Julia: compress via zlib.compress2; Browser: decompress via `DecompressionStream("deflate")`
# It uses `await`, so it only works inside an async script (PlotlyLight draws plots in async script)
struct Compressed{T}
    x::T
    level::Int  # zlib compression level: 0 (none) to 9 (smallest)
    function Compressed(x::T; level::Integer=6) where {T}
        0 ≤ level ≤ 9 || throw(ArgumentError("`Compressed` level must be 0 to 9.  Found $level."))
        new{T}(x, level)
    end
end

# zlib format (what `DecompressionStream("deflate")` reads)
function zlib_compress(x::AbstractVector{UInt8}, level::Integer)
    n = Culong(length(x))
    d = Ref(@ccall libz.compressBound(n::Culong)::Culong)
    out = Vector{UInt8}(undef, d[])
    ret = @ccall libz.compress2(out::Ptr{UInt8}, d::Ref{Culong}, x::Ptr{UInt8}, n::Culong, level::Cint)::Cint
    ret == 0 || error("zlib compress2 failed with code $ret")
    resize!(out, d[])
end

# JS: base64 `b` of zlib-compressed bytes, decompressed into a `Response`
const INFLATE_JS = "new Response(new Blob([Uint8Array.fromBase64?.(b) ?? Uint8Array.from(atob(b), c => c.charCodeAt(0))])" *
    ".stream().pipeThrough(new DecompressionStream(\"deflate\")))"

# JS: the flat, row-major array `x` nested into rows (as plotly.js reads matrices and 3-d arrays).  `slice` is the
# method that takes a row: "subarray" (a view) for typed arrays, "slice" (a copy) for Arrays.
_reshape_js(dims; slice="subarray") = length(dims) == 1 ?
    "return x;" :
    """
    const rows = (x, dims) => Array.from({length: dims[0]}, (_, i) => {
        const n = x.length / dims[0], row = x.$slice(i * n, (i + 1) * n);
        return dims.length == 2 ? row : rows(row, dims.slice(1));
    });
    return rows(x, $(json(collect(dims))));
    """

function inflate_js(c::Compressed{<:AbstractArray{<:Real}}; rtol=0.0, atol=0.0)
    T = haskey(JS_ARRAYS, eltype(c.x)) ? eltype(c.x) : min_type(c.x; rtol, atol)
    isnothing(T) && return inflate_json(c)
    y = convert(Array{T}, _rowmajor(c.x))
    b64 = base64encode(zlib_compress(reinterpret(UInt8, vec(y)), c.level))
    RawJS("""
    (await (async b => {
        const x = new $(JS_ARRAYS[T])(await $INFLATE_JS.arrayBuffer());
        $(_reshape_js(size(c.x)))
    })("$b64"))
    """)
end

# Bools: one byte each (zlib shrinks the 0s and 1s to about a bit each), read back as `true`/`false`
function inflate_js(c::Compressed{<:AbstractArray{Bool}}; kw...)
    y = convert(Array{UInt8}, _rowmajor(c.x))
    b64 = base64encode(zlib_compress(vec(y), c.level))
    RawJS("""
    (await (async b => {
        const x = Array.from(new Uint8Array(await $INFLATE_JS.arrayBuffer()), v => v === 1);
        $(_reshape_js(size(c.x); slice="slice"))
    })("$b64"))
    """)
end

# Everything else is compressed as JSON
inflate_js(c::Compressed; kw...) = inflate_json(c)

function inflate_json(c::Compressed)
    b64 = base64encode(zlib_compress(codeunits(json(c.x)), c.level))
    RawJS("""(await (b => $INFLATE_JS.json())("$b64"))""")
end

json(io::IO, c::Compressed) = json(io, inflate_js(c; settings.compression.rtol, settings.compression.atol))

# `settings.compression`: the trace's arrays (including nested ones, e.g. `marker.color`) with at least `n` elements
function compress!(trace::AbstractDict, (; level, rtol, atol, n))
    foreach(collect(keys(trace))) do k
        v = trace[k]
        if v isa AbstractDict
            compress!(v, (; level, rtol, atol, n))
        elseif v isa AbstractArray && length(v) ≥ n
            T = eltype(v) <: Real ? min_type(v; rtol, atol) : nothing
            trace[k] = Compressed(isnothing(T) ? v : convert(AbstractArray{T}, v); level)
        end
    end
    return trace
end
