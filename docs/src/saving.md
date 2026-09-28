# Saving

### Saving Plots As HTML

```julia
p = plot(y=rand(10))

PlotlyLight.save(p, "myplot.html")
```

!!! note "Viewing Offline"
    Saved plots load plotly.js from its CDN, so viewing them needs internet access.  Use `PlotlyLight.preset.source.local!()` before you save the plot to load it from the copy that comes with PlotlyLight instead, which works offline on this computer.



### Save Plots as Image via [PlotlyKaleido.jl](https://github.com/JuliaPlots/PlotlyKaleido.jl)

```julia
using PlotlyKaleido

PlotlyKaleido.start()

(;data, layout, config) = p

PlotlyKaleido.savefig((; data, layout, config), "myplot.png")
```
