# Settings

Occasionally the `PlotlyLight.preset`s aren't enough.  Low level user-configurable settings are available in `PlotlyLight.settings`:

```julia
settings.div::Cobweb.Node           # The plot-div
settings.layout::EasyConfig.Config  # default `layout` for all plots
settings.config::EasyConfig.Config  # default `config` for all plots
settings.js_deps::OrderedDict{Symbol,String} # name => URL of scripts to load before plotting (`:plotly` first)
settings.compression_level::Int     # default zlib level (0 to 9) for `Compressed`
```

Check out e.g. `PlotlyLight.Settings()` to examine default values.

## Compression

Numeric arrays are written as JSON.  To send one to plotly.js as base64-encoded binary (a plotly.js "typed array") instead, wrap it in `TypedArray`:

```julia
p = plot.scatter(x = TypedArray(1:10_000), y = TypedArray(randn(10_000)))
```

It's written in the smallest type plotly.js can decode that holds every value exactly: `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `Float32`, or `Float64` (plotly.js has no `Float16` or `Int64`).  This roughly halves the size of float data, and plotly.js decodes it without any extra scripts.  To also allow `Float32` when it's close enough, give a relative or absolute tolerance: `TypedArray(y, 1e-5)` or `TypedArray(y, 0.0, 1e-3)`.

Arrays that plotly.js can't decode as typed arrays (`Bool`s, non-numbers, `missing`s, empty arrays, or more than 3 dimensions) are written as JSON.  `typed_array(x; rtol=0.0, atol=0.0)` returns the `(; bdata, dtype, shape)` that is written for `x`.

To compress any value (an array, including one of strings, or a whole `Config`), wrap it in `Compressed`:

```julia
p = plot.scatter(y = Compressed(cumsum(randn(10^6))), text = Compressed(labels))
```

Numeric arrays become JavaScript typed arrays (`Uint8Array`, `Float32Array`, `Float16Array`, …) of the same element type, so you choose their size, e.g. `Compressed(Float32.(y))`.  Element types that JavaScript has no array of (e.g. `Int64`) are converted to the smallest type that holds every value exactly.  Matrices and 3-d arrays become arrays of rows, as plotly.js reads them.  Anything else (strings, `Bool`s, `Config`s, …) is sent as JSON.  Values are never changed.

The bytes are zlib-compressed and base64-encoded, and the browser decompresses them with [`DecompressionStream`](https://developer.mozilla.org/en-US/docs/Web/API/DecompressionStream) (Chrome 80, Firefox 113, Safari 16.4) while drawing the plot.  `Float16Array` needs Chrome 135, Firefox 129, or Safari 18.2.

`Compressed(x; level)` sets the zlib level, from `0` (no compression: the data's binary size, plus a third for base64) to `9` (smallest, and slowest).  The default is `settings.compression_level` (`0`).
