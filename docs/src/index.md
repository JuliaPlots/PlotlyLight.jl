# Introduction

PlotlyLight.jl is a speedy lightweight interface for creating [Plotly.js](https://plotly.com/javascript/) plots from Julia.

## ✨ Features

- 🚀 Fastest time-to-first-plot in Julia!
- 🌐 Use the [Plotly.js Javascript documentation](https://plotly.com/javascript/) directly.  No magic syntax: just JSON.
- 📂 Set deeply-nested keys easily, e.g. `myplot.layout.xaxis.title.font.family = "Arial"`.
- 📊 The Same [built-in themes](https://plotly.com/python/templates/) as Plotly's python package.

## 🚀 Quickstart

```@example
using PlotlyLight

# Change template
preset.template.plotly_dark!()

# Make Plot
p = plot(x = 1:20, y = cumsum(randn(20)), type="scatter", mode="lines+markers")

# Make changes
p.layout.title.text = "My Title!"

# Re-display to see updated plot
p
```
