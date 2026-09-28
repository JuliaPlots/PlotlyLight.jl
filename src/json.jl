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

json(x) = sprint(json, x)

# Iterables --> array.  Anything else without a method is an error.
function json(io::IO, x)
    applicable(iterate, x) || throw(unsupported(x))
    json_join(io, x, '[', ']')
end

unsupported(x) = ArgumentError("""
    PlotlyLight doesn't know how to write a `$(typeof(x))` as JSON.  Convert it to a supported type, or add a method:
        PlotlyLight.json(io::IO, x::$(typeof(x))) = <write x's JSON to io>
    """)


struct RawJS
    code::String
end
json(io::IO, x::RawJS) = print(io, x.code)

# Strings: JSON escapes, plus `<`, `>`, and `&`
function json(io::IO, x::AbstractString)
    s = x isa Union{String, SubString{String}} ? x : String(x)
    print(io, '"')
    start = 1  # first byte not yet written
    GC.@preserve s begin
        for i in 1:ncodeunits(s)
            b = codeunit(s, i)
            e = b < 0x80 ? JSON_ESCAPES[b + 1] : nothing
            isnothing(e) && continue
            unsafe_write(io, pointer(s, start), i - start)  # the unescaped run before byte `i`
            print(io, e)
            start = i + 1
        end
        unsafe_write(io, pointer(s, start), ncodeunits(s) - start + 1)
    end
    print(io, '"')
end

# Escapes by byte.  Only ASCII bytes are escaped, and those never occur inside a multi-byte UTF-8 character, so the
# string can be scanned (and written) byte-wise.
const JSON_ESCAPES = let t = Vector{Union{Nothing, String}}(nothing, 128)
    for b in 0x00:0x1f  # control characters
        t[b + 1] = "\\u" * string(b; base=16, pad=4)
    end
    for (c, e) in ('"' => "\\\"", '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t",
                   '<' => "\\u003c", '>' => "\\u003e", '&' => "\\u0026")
        t[UInt8(c) + 1] = e
    end
    t
end
json(io::IO, x::Union{AbstractChar, Symbol, Dates.TimeType}) = json(io, string(x))

# Numbers: Integers (and Bools) as-is, other Reals (Rational, Irrational, …) as floats, and NaN/±Inf as null (a gap
# in the plot)
json(io::IO, x::Number) = throw(unsupported(x))
json(io::IO, x::Real) = (y = float(x); isfinite(y) ? print(io, y) : print(io, "null"))
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
# `x` with arrays of numbers/strings (at least `c.min_length` long) replaced by `RawJS` that decodes them in the
# browser.  The calls are `await`ed inside NewPlotScript's async function, and defined by COMPRESSION_SRC.
compress(c::Compression, x) = x
compress(c::Compression, x::Union{Tuple, NamedTuple, AbstractArray}) = map(v -> compress(c, v), x)
compress(c::Compression, x::AbstractDict) = Config(map(((k, v),) -> k => compress(c, v), collect(x))...)
compress(c::Compression, x::Pair) = x.first => compress(c, x.second)

function compress(c::Compression, x::AbstractVecOrMat{<:Real})
    (length(x) < c.min_length || eltype(x) <: Bool) && return x
    T = _compressed_json_type(x, c)
    data = vec(T.(transpose(x)))  # JS matrices are row-major
    RawJS("await numArrFromBase64($(JS_TYPED_ARRAYS[T]),'$(base64encode(zlib_compress(data)))',$(join(size(x), ',')))")
end

function compress(c::Compression, x::AbstractVector{<:AbstractString})
    length(x) < c.min_length && return x
    RawJS("await strVecFromBase64('$(base64encode(zlib_compress(Vector{UInt8}(json(x)))))')")
end

# compress data into something `DecompressionStream("deflate")` can read.
function zlib_compress(data::DenseArray)
    n = Ref(ccall((:compressBound, libz), Culong, (Culong,), sizeof(data)))
    out = Vector{UInt8}(undef, n[])
    status = ccall((:compress2, libz), Cint, (Ptr{UInt8}, Ref{Culong}, Ptr{Cvoid}, Culong, Cint),
                   out, n, data, sizeof(data), -1)  # -1 is Z_DEFAULT_COMPRESSION
    status == 0 || error("zlib compress2 failed with status $status")
    return resize!(out, n[])
end

const JS_INT_TYPES = (UInt8, Int8, UInt16, Int16, UInt32, Int32)

const JS_TYPED_ARRAYS = Dict(
    UInt8   => "Uint8Array",    Int8    => "Int8Array",
    UInt16  => "Uint16Array",   Int16   => "Int16Array",
    UInt32  => "Uint32Array",   Int32   => "Int32Array",
    Float16 => "Float16Array",  Float32 => "Float32Array", Float64 => "Float64Array"
)

# Smallest JS typed array element type for `x`.  JS has no Int64 typed array (BigInt64Array holds BigInts,
# which plotly.js can't use), so integers outside the Int32/UInt32 range are treated as floats.
function _compressed_json_type(x::AbstractArray{<:Integer}, c::Compression)
    isempty(x) && return UInt8
    mn, mx = extrema(x)
    i = findfirst(T -> typemin(T) <= mn && mx <= typemax(T), JS_INT_TYPES)
    isnothing(i) ? _compressed_float_type(x, c) : JS_INT_TYPES[i]
end
_compressed_json_type(x::AbstractArray{<:Real}, c::Compression) = _compressed_float_type(x, c)

# Smallest of `c.float_types` whose rounding error is at most `c.rtol` of the data's range
function _compressed_float_type(x::AbstractArray{<:Real}, c::Compression)
    types = sort!(collect(c.float_types); by = sizeof)
    isempty(x) && return first(types)
    mn, mx = extrema(x)
    if !(isfinite(mn) && isfinite(mx))  # NaN and ±Inf are exact in every float type, so skip them
        finite = Iterators.filter(isfinite, x)
        isempty(finite) && return first(types)
        mn, mx = extrema(finite)
    end
    scale = mx > mn ? mx - mn : abs(mx)  # constant data: compare with the value itself
    tol = c.rtol * Float64(scale)
    i = findfirst(T -> _fits(T, x, tol), types[1:end-1])  # the largest type is the fallback; don't test it
    return isnothing(i) ? last(types) : types[i]
end

# Function barrier: `T` comes from an untyped Tuple, so specialize here rather than dispatch per element
_fits(::Type{T}, x, tol) where {T} = all(v -> !isfinite(v) || abs(Float64(T(v)) - Float64(v)) <= tol, x)

#------------------------------------------------------------------------------# JS decoders
# Attach JS functions to `window`.  Pluto runs any <script> in its own function and we need to find them
const COMPRESSION_SRC = h.script(raw"""
    window.base64ToBytes = function(s) {
        if (Uint8Array.fromBase64) return Uint8Array.fromBase64(s);
        const bin = atob(s), bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return bytes;
    }
    window.inflateBase64 = function(base64_dat) {
        const stream = new Response(base64ToBytes(base64_dat)).body.pipeThrough(new DecompressionStream("deflate"));
        return new Response(stream).arrayBuffer();
    }
    window.numArrFromBase64 = async function(T, base64_dat, ...dims) {
        const arr = new T(await inflateBase64(base64_dat));
        if (dims.length == 1) {
            return arr;
        } else if (dims.length == 2) {
            const arr2d = [];
            for (let i = 0; i < arr.length; i += dims[1]) {
                arr2d.push(arr.subarray(i, i + dims[1]));
            }
            return arr2d;
        } else {
            throw new Error(`>2 dims not implemented.`);
        }
    }
    window.strVecFromBase64 = async function(base64_dat) {
        return JSON.parse(new TextDecoder().decode(await inflateBase64(base64_dat)));
    }
    """)
