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

_bdata(x) = base64encode(permutedims(x, ndims(x):-1:1))  # row-major, as plotly.js reads it
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

#------------------------------------------------------------------------------# Compress
struct Compressed
    x
end
