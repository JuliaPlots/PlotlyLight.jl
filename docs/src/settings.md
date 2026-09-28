# Settings

Occasionally the `PlotlyLight.preset`s aren't enough.  Low level user-configurable settings are available in `PlotlyLight.settings`:

```julia
settings.src::Cobweb.Node           # plotly.js script loader
settings.div::Cobweb.Node           # The plot-div
settings.layout::EasyConfig.Config  # default `layout` for all plots
settings.config::EasyConfig.Config  # default `config` for all plots
settings.reuse_preview::Bool        # In the REPL, open plots in same page (true, the default) or different pages.
settings.page_css::Cobweb.Node      # CSS to inject at the top of the page
settings.js_deps::OrderedDict{Symbol,String} # name => URL of scripts to load before plotting (`:plotly` first)
```

Check out e.g. `PlotlyLight.Settings()` to examine default values.

## Adding Presets

Each preset is a method of `PlotlyLight.preset!`, so you (or a package) can add presets, and new groups, by adding methods.  They show up in `preset`'s display and tab completion like the built-in ones:

```julia
PlotlyLight.preset!(::Val{:template}, ::Val{:mytheme}) = (PlotlyLight.settings.layout.template = my_template; nothing)

preset.template.mytheme!()
```

Existing presets can't be replaced: redefining a method is an error during precompilation.

## Compression

When a plot is displayed, numeric arrays with at least 100 elements are sent to plotly.js as base64-encoded binary (plotly.js "typed arrays") rather than JSON, in the smallest type that holds them.  This roughly halves the size of float data, never changes a value, and plotly.js decodes it without any extra scripts.

For other options, compress the plot yourself with `PlotlyLight.compress` (plots that are already compressed are left as they are when displayed):

```julia
p = plot.scatter(x = 1:10_000, y = randn(10_000))

PlotlyLight.compress(p; min_length=100, float_rtol=1e-5, ranges=true)
```

- `min_length` (default `100`): shorter arrays are left as JSON.
- `float_rtol` (default `0`): floats become `Float32` if that rounds them by at most `float_rtol` of the array's range, otherwise `Float64`.  `0` never changes a value; `1e-5` is under a pixel even when zoomed in 100x, and halves most float data again.  Integers always use the smallest of `UInt8`, `Int8`, …, `Int32` that holds them.
- `ranges` (default `false`): a trace's evenly spaced `x` (or `y`, `r`, `theta`), e.g. from `1:10_000`, becomes `x0` and `dx` (`y0` and `dy`, …): two numbers instead of an array.  It's only done where plotly.js rebuilds exactly the same values (for `scatter`, `scattergl`, `bar`, `funnel`, `waterfall`, `quiver`, `heatmap`, `contour`, `scatterpolar`, `scatterpolargl`, and `barpolar` traces).

To choose the type of one array, wrap it: `plot.scatter(y = PlotlyLight.JSTypedArray{Float32}(y))`.  plotly.js typed arrays can hold `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `Float32`, and `Float64` (no `Float16` or `Int64`).
