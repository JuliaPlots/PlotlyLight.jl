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


#------------------------------------------------------------------------------# compression
# Multiple ways to compress data with plotly:
#
# 1) Ranges can be reduced to start/step: x --> x0 and dx
# 2) Arrays can use Base64 encoding with any of DTYPES e.g. (x: data) --> (x: { bdata: "...", dtype: "float32"})
# 3) E.g. DecompressionStream("zstd") in browser, TranscodingStreams for compression on Julia side

# smallest-to-largest
const INT_DTYPES = (UInt8, Int8, UInt16, Int16, UInt32, Int32)
const FLOAT_DTYPES = (Float32, Float64)
const DTYPES = (INT_DTYPES..., FLOAT_DTYPES...)

function _bdata(x::AbstractVecOrMat, T)
    (bdata = base64encode(T.(permutedims(x))), dtype=lowercase(string(T)), shape=join(size(x), ','))
end

# Can type `T` represent `x` within allowable rtol/atol
_fits(T, x; rtol=0.0, atol=0.0, nans=true) = isapprox(Float64(x), T(x); rtol, atol, nans=true)

# `kw` passes to isapprox(...; kw...) for narrowing float data
function bdata(x::AbstractVecOrMat{<:Real}; rtol=0.0, atol=0.0)
    (isempty(x) || eltype(x) <: Bool) && return x
    if all(isinteger, x)  # isinteger implies isfinite
        (a, b) = extrema(x)
        i = findfirst(T -> typemin(T) ≤ a && b ≤ typemax(T), INT_DTYPES)
        isnothing(i) || return _bdata(x, INT_DTYPES[i])
    end
    i = findfirst(T -> all(v -> _fits(T, v; rtol, atol), x), FLOAT_DTYPES)
    _bdata(x, FLOAT_DTYPES[i])
end

function bdata!(trace::Config; kw...)
    for (k, v) in trace
        if v isa Config
            bdata!(v; kw...)
        elseif v isa AbstractVecOrMat
            trace[k] = bdata(v; kw...)
        end
    end
    trace
end

bdata!(p::Plot; kw...) = foreach(tr -> bdata!(tr; kw...))
