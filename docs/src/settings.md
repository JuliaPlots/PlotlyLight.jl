# Settings

Occasionally the `PlotlyLight.preset`s aren't enough.  Low level user-configurable settings are available in `PlotlyLight.settings`:

```julia
settings.src::Cobweb.Node           # plotly.js script loader
settings.div::Cobweb.Node           # The plot-div
settings.layout::EasyConfig.Config  # default `layout` for all plots
settings.config::EasyConfig.Config  # default `config` for all plots
settings.reuse_preview::Bool        # In the REPL, open plots in same page (true, the default) or different pages.
settings.page_css::Cobweb.Node      # CSS to inject at the top of the page
settings.use_iframe::Bool           # Use an iframe to display the plot (default=false)
settings.iframe_style::String       # style attributes for the iframe
settings.src_inject::Vector         # Code (typically scripts) to inject into the html
settings.compression::Compression   # Compression of large arrays (see below)
```

Check out e.g. `PlotlyLight.Settings()` to examine default values.

## Compression

With compression on (`preset.display.compress!()`), large numeric and string arrays are sent to the browser zlib-compressed and decoded there, which makes pages with lots of data much smaller.  Configure it with the fields of `settings.compression`:

```julia
settings.compression.on::Bool             # Compress arrays (default=false)
settings.compression.min_length::Int      # Arrays with fewer elements are left as plain JSON (default=100)
settings.compression.float_types::Tuple   # Float types to choose from (default=(Float64, Float32, Float16))
settings.compression.rtol::Float64        # Max rounding error, relative to the data's range (default=1e-5)
```

Each float array uses the smallest of `float_types` whose rounding error stays within `rtol` of the array's range (under a pixel even when zoomed in 100x).  Integer arrays use the smallest integer type that holds them.

Compressed plots need a browser with `DecompressionStream` (Chrome/Edge 80+, Firefox 113+, Safari 16.4+).  `Float16` data additionally needs `Float16Array` (Chrome/Edge 135+, Firefox 129+, Safari 18.2+), so remove `Float16` from `float_types` if older browsers matter.
