# Saving

### Saving Plots As HTML

```julia
p = plot(y=rand(10))

PlotlyLight.save(p, "myplot.html")
```

!!! note "Viewing Offline"
    Saved plots load plotly.js from its CDN, so viewing them needs internet access.  Use `PlotlyLight.preset.source.local!()` before you save the plot to load it from the copy that comes with PlotlyLight instead, which works offline on this computer.



### Saving Plots As Images

```julia
PlotlyLight.save(p, "myplot.svg")  # or .png, .jpg/.jpeg, .webp

PlotlyLight.save(p, "myplot.png"; width=800, height=600, scale=2)

bytes = PlotlyLight.image(p, "svg")  # the image's bytes, without saving a file
```

plotly.js draws the image in a headless copy of a Chrome, Chromium, or Edge you already have installed (set `ENV["CHROME"]` to the path of the one to use), so it matches what the plot looks like in a browser, and `TypedArray` and `Compressed` data work as usual.  Each image takes about a second, mostly spent starting the browser.

- `width` and `height` default to the plot's `layout.width` and `layout.height`, otherwise 700 × 450.
- `scale` multiplies the pixels of a PNG, JPEG, or WebP.
- SVGs name their fonts rather than embedding them, so text is drawn with the fonts of whatever views the SVG.

### Saving Images without Chrome, via [PlotlyKaleido.jl](https://github.com/JuliaPlots/PlotlyKaleido.jl)

Kaleido comes with its own browser.  Give it plain arrays: it doesn't know about `TypedArray` or `Compressed`.

```julia
using PlotlyKaleido

PlotlyKaleido.start()

(;data, layout, config) = p

PlotlyKaleido.savefig((; data, layout, config), "myplot.png")
```
