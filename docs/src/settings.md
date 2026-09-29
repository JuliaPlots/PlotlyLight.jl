# Settings

Occasionally the `PlotlyLight.preset`s aren't enough.  Low level user-configurable settings are available in `PlotlyLight.settings`:

```julia
settings.div::Cobweb.Node           # The plot-div
settings.layout::EasyConfig.Config  # default `layout` for all plots
settings.config::EasyConfig.Config  # default `config` for all plots
settings.js_deps::OrderedDict{Symbol,String}  # name => URL of scripts to load before plotting (`:plotly` first)
settings.compression::NamedTuple    # (; level, rtol, atol, n): compress every plot's large arrays (see Compression)
```

Check out e.g. `PlotlyLight.Settings()` to examine default values.

For `TypedArray` and `Compressed`, which make large plots smaller, see [Compression](compression.md).
