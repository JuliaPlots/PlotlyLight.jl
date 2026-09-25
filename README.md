[![Build](https://github.com/JuliaComputing/PlotlyLight.jl/workflows/CI/badge.svg)](https://github.com/JuliaComputing/PlotlyLight.jl/actions?query=workflow%3ACI+branch%3Amaster)
[![Docs Build](https://github.com/JuliaComputing/PlotlyLight.jl/actions/workflows/Docs.yml/badge.svg)](https://github.com/JuliaComputing/PlotlyLight.jl/actions/workflows/Docs.yml)
[![Codecov](https://codecov.io/gh/JuliaComputing/PlotlyLight.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaComputing/PlotlyLight.jl)

<h1 align="center">PlotlyLight</h1>

<p align="center"><b>PlotlyLight</b> is an ultra-lightweight interface for working with <a href="https://plotly.com/javascript">Plotly.js</a>.</p>

> [!IMPORTANT]
> The PlotlyLight docs will not teach you how to use the Plotly.js library.  If you are new to Plotly.js, you may want to start with the [official documentation](https://plotly.com/javascript/).


<br><br>

## ✨ Features

- 🚀 Fastest time-to-first-plot in Julia!
- 🌐 Use the [Plotly.js Javascript documentation](https://plotly.com/javascript/) directly. No magic syntax.
- 📂 Set deeply-nested keys easily, e.g. `myplot.layout.xaxis.title.font.family = "Arial"`.
- 📊 The Same [built-in themes](https://plotly.com/python/templates/) as Plotly's python package.
- 🗜️ Use `PlotlyLight.preset.display.compress!()` to automatically compress large arrays and produce plots that download and display faster. 

<br><br>

## 🚀 Quickstart

```julia
using PlotlyLight

preset.template.plotly_dark!()  # Change template

p = plot(x = 1:20, y = cumsum(randn(20)), type="scatter", mode="lines+markers")  # Make plot

p.layout.title.text = "My Title!"  # Make changes

p  # `display(p)` to see the updated plot
```


<p align="center">
    <img width=650 src="https://user-images.githubusercontent.com/8075494/213164013-3ba1a108-122a-4339-a0a2-fa2175fa06e3.png">
</p>
