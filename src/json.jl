
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

struct JSON{T}
    x::T
end
json(io::IO, x::JSON) = print(io, x.x)


json(x) = sprint(json, x)
json(io::IO, args...) = foreach(x -> json(io, x), args)

# Strings
json(io::IO, x::Union{AbstractChar, AbstractString, Symbol}) = print(io, '"', x, '"')
json(io::IO, x::DateTime) = json(io, Dates.format(x, "YYYY-mm-dd HH:MM:SS"))
json(io::IO, x::Date) = json(io, Dates.format(x, "YYYY-mm-dd"))

# Numbers
json(io::IO, x::Real) = isfinite(x) ? print(io, x) : print(io, "null")
json(io::IO, x::Rational) = json(io, float(x))

# Nulls
json(io::IO, ::Union{Missing, Nothing}) = print(io, "null")

# Bools
json(io::IO, x::Bool) = print(io, x ? "true" : "false")

# Arrays
_json_generic_arr(io::IO, x::AbstractVector) = json_join(io, x, ',', '[', ']')
_json_generic_arr(io::IO, x::AbstractArray) = json(io, eachslice(x; dims=1))
json(io::IO, x::AbstractVector) = _json_generic_arr(io, x)
json(io::IO, x::AbstractArray) = _json_generic_arr(io, x)

# Objects
json(io::IO, x::Pair) = json(io, x.first, JSON(':'), x.second)
json(io::IO, x::Union{NamedTuple, AbstractDict}) = json_join(io, pairs(x), ',', '{', '}')



# Compress certain array types for some (huge) space savings for large arrays

json_compression_src_inject = [
    h.script(src="https://cdn.jsdelivr.net/npm/fflate@0.8.2/umd/index.js"),
    h.script(raw"""
    function numArrFromBase64(T, base64_dat, ...dims) {
        arr = new T(fflate.unzlibSync(Uint8Array.from(atob(base64_dat), c => c.charCodeAt(0))).buffer)
        if (dims.length == 1) {
            return arr; 
        } else if (dims.length == 2) {
            arr2d = [];
            for (let i = 0; i < arr.length; i += dims[1]) {
                arr2d.push(arr.subarray(i, i + dims[1]));
            }
            return arr2d;
        } else {
            throw new Error(`>2 dims not implemented.`);
        }
    }
    function strVecFromBase64(base64_dat, lens) {
        strs = fflate.strFromU8(fflate.unzlibSync(Uint8Array.from(atob(base64_dat), c => c.charCodeAt(0))));
        arr = [];
        cur = 0;
        for (var i = 0; i < lens.length; i++) {
            arr.push(strs.slice(cur, cur + lens[i]));
            cur += lens[i];
        }
        return arr;
    }
    """)
]

json(io::IO, arr::AbstractVector{<:AbstractFloat}) = _json_num_arr(io, arr)
json(io::IO, arr::AbstractMatrix{<:AbstractFloat}) = _json_num_arr(io, arr)
json(io::IO, arr::AbstractVector{<:Integer}) = _json_num_arr(io, arr)
json(io::IO, arr::AbstractMatrix{<:Integer}) = _json_num_arr(io, arr)

function _to_js_eltype(arr::AbstractArray{<:AbstractFloat})
    # be opinionated and cap at Float32, which should be enough for
    # plotting, halving filesize vs Float64
    T = (eltype(arr) == Float16) ? Float16 : Float32
    return convert(AbstractArray{T}, arr)
end

function _to_js_eltype(arr::AbstractArray{<:Integer})
    # find the smallest integer type that can represent the data
    mn, mx = extrema(arr)
    types = (UInt8, Int8, UInt16, Int16, UInt32, Int32)
    i = findfirst(t -> mn >= typemin(t) && mx <= typemax(t), types)
    isnothing(i) && error("Integer values in plot data are too large to fit in UInt32 or Int32.")
    T = types[i]
    return convert(AbstractArray{T}, arr)
end

function _json_num_arr(io::IO, arr)
    if settings.compress
        js_arr = _to_js_eltype(arr)
        T = eltype(js_arr)
        base64_dat = base64encode(transcode(ZlibCompressor, Vector(reinterpret(UInt8, view(transpose(js_arr), :)))))
        dims = join(size(js_arr), ',')
        T_js = string(T)[1] * lowercase(string(T)[2:end])
        print(io, "numArrFromBase64($(T_js)Array,'", base64_dat, "',", dims, ")")
    else
        _json_generic_arr(io, arr)
    end
end

function json(io::IO, arr::AbstractVector{<:AbstractString})
    if settings.compress
        # store a (compressed) contatenation of the strings and indices where each element starts
        base64_dat = base64encode(transcode(ZlibCompressor, join(arr)))
        print(io, "strVecFromBase64('", base64_dat, "',")
        json(io, length.(arr))
        print(io, ")")
    else
        _json_generic_arr(io, arr)
    end
end