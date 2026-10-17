# Plotly.js Source

Change where the plotly.js script gets loaded from via `preset.source.<option>!()`.

```julia
preset.source.none!()       # Don't load it (e.g. the page already has plotly.js).
preset.source.cdn!()        # Use the official plotly.js CDN (the default).
preset.source.local!()      # Use the copy of plotly.js that comes with PlotlyLight (works offline on this computer).
```
