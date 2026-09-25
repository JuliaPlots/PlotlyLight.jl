#-----------------------------------------------------------------------------# json
function json_join(io::IO, itr, sep, left, right)
    print(io, left)
    for (i, item) in enumerate(itr)
        i == 1 || print(io, sep)
        json(io, item)
    end
    print(io, right)
end

json(io::IO, x) = json_join(io, x, ',', '[', ']')  # ***FALLBACK METHOD***

json(x) = sprint(json, x)

# Strings
# JSON-escaped, and `<` as `<` so data can't end the surrounding `<script>` (e.g. "</script>").
# (HTML escaping like `Cobweb.escape` is wrong here: entities aren't decoded inside `<script>`.)
json(io::IO, x::Union{AbstractChar, AbstractString, Symbol}) = print(io, replace(JSON3.write(string(x)), '<' => "\\u003c"))
json(io::IO, x::DateTime) = json(io, Dates.format(x, "YYYY-mm-dd HH:MM:SS"))
json(io::IO, x::Date) = json(io, Dates.format(x, "YYYY-mm-dd"))

# Numbers
json(io::IO, x::Real) = isfinite(x) ? print(io, x) : print(io, "null")
json(io::IO, x::Rational) = json(io, float(x))

# Nulls
json(io::IO, ::Union{Missing, Nothing}) = print(io, "null")

# Bools
json(io::IO, x::Bool) = print(io, x ? "true" : "false")

# Objects
json(io::IO, x::Pair) = (json(io, x.first); print(io, ':'); json(io, x.second))
json(io::IO, x::Union{NamedTuple, AbstractDict}) = json_join(io, pairs(x), ',', '{', '}')

# Arrays (a matrix is an array of rows)
json_array(io::IO, x::AbstractArray) = json_join(io, ndims(x) == 1 ? x : eachslice(x; dims=1), ',', '[', ']')
json(io::IO, x::AbstractArray) = json_array(io, x)

#------------------------------------------------------------------------------# compression
function json(io::IO, x::AbstractVecOrMat{<:Real})
    c = get(io, :plotlylight_compression, nothing)
    (isnothing(c) || length(x) < c.min_length || eltype(x) <: Bool) && return json_array(io, x)
    T = _compressed_json_type(x, c)
    data = vec(T.(transpose(x)))  # JS matrices are row-major
    print(io, "await numArrFromBase64(", JS_TYPED_ARRAYS[T], ",'", base64encode(zlib_compress(data)), "',", join(size(x), ','), ")")
end

function json(io::IO, x::AbstractVector{<:AbstractString})
    c = get(io, :plotlylight_compression, nothing)
    (isnothing(c) || length(x) < c.min_length) && return json_array(io, x)
    print(io, "await strVecFromBase64('", base64encode(zlib_compress(Vector{UInt8}(JSON3.write(x)))), "')")
end

# zlib-format deflate (what the browser's `DecompressionStream("deflate")` reads) via zlib's `compress2`
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

# Smallest of `c.float_types` whose rounding error is at most `c.rtol` of the data's range, i.e. under a pixel
# even when zoomed in 100x.  Error relative to the range (not the values) is what's visible: GPS coordinates
# (≈45.123456) need Float64, while integer-valued data is exact in Float16.  Falls back to the largest type.
# Float16Array needs Chrome/Edge 135 (April 2025), Firefox 129 (August 2024) or Safari 18.2 (December 2024).
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
# Injected into the page when compression is on.  DecompressionStream is asynchronous, so the calls written by
# `json` are `await`ed inside NewPlotScript's async draw function.  Attached to `window` because some hosts
# (e.g. Pluto) run each <script> inside its own function, where plain `function` declarations wouldn't be
# visible to the plot's script.
COMPRESSION_SRC = h.script(raw"""
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
