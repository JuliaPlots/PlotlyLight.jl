# Settings

Occasionally the `PlotlyLight.preset`s aren't enough.  Low level user-configurable settings are available in `PlotlyLight.settings`:

```julia
settings.div::Cobweb.Node           # The plot-div
settings.layout::EasyConfig.Config  # default `layout` for all plots
settings.config::EasyConfig.Config  # default `config` for all plots
settings.js_deps::OrderedDict{Symbol,String} # name => URL of scripts to load before plotting (`:plotly` first)
```

Check out e.g. `PlotlyLight.Settings()` to examine default values.

## Compression

Numeric arrays are written as JSON.  To send one to plotly.js as base64-encoded binary (a plotly.js "typed array") instead, wrap it in `TypedArray`:

```julia
p = plot.scatter(x = TypedArray(1:10_000), y = TypedArray(randn(10_000)))
```

It's written in the smallest type plotly.js can decode that holds every value exactly: `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `Float32`, or `Float64` (plotly.js has no `Float16` or `Int64`).  This roughly halves the size of float data, and plotly.js decodes it without any extra scripts.  To also allow `Float32` when it's close enough, give a relative or absolute tolerance: `TypedArray(y, 1e-5)` or `TypedArray(y, 0.0, 1e-3)`.

Arrays that plotly.js can't decode as typed arrays (`Bool`s, non-numbers, `missing`s, empty arrays, or more than 3 dimensions) are written as JSON.  `typed_array(x; rtol=0.0, atol=0.0)` returns the `(; bdata, dtype, shape)` that is written for `x`.
