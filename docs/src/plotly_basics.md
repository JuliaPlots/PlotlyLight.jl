# Plotly Basics

Plotly.js is a JavaScript library that allows you to create interactive plots in the browser.

PlotlyLight provide a lightweight interface over the Javascript, so it is worthwhile to learn how the Plotly.js library works.

## What is a Plot?

The core JS function that generates a plot is `Plotly.newPlot(data, layout, config)`, where `data` is a JSON array of objects and `layout`/`config` are JSON objects.  Each element of `data` is called a **trace** (data along with specifications on how to plot it).

!!! note "Plotly.js Schema"
    The Plotly.js specification is available as a [JSON schema](https://json-schema.org) (raw JSON [here](https://api.plot.ly/v2/plot-schema?format=json&sha1=%27%27)).

    PlotlyLight includes this schema as `PlotlyLight.Schema`, e.g. `PlotlyLight.Schema.traces[:scatter][:attributes]`.

## What is a Trace?

- A **trace** is a JSON object that specifies how data should be represented in a plot.
- There are many different trace *types* (e.g. "scatter" for scatterplots, "box" for boxplots).


!!! note "Tab Auto-Complete"
    PlotlyLight's `plot` function enables tab-autocomplete for trace types:
    ```julia
    julia> plot.<TAB>
    # bar                 barpolar            box                 candlestick
    # carpet              choropleth          choroplethmapbox    cone
    # contour             contourcarpet       densitymapbox       funnel
    # funnelarea          heatmap             heatmapgl           histogram
    # histogram2d         histogram2dcontour  icicle              image
    # indicator           isosurface          mesh3d              ohlc
    # parcats             parcoords           pie                 pointcloud
    # sankey              scatter             scatter3d           scattercarpet
    # scattergeo          scattergl           scattermapbox       scatterpolar
    # scatterpolargl      scattersmith        scatterternary      splom
    # streamtube          sunburst            surface             table
    # treemap             violin              volume              waterfall
    ```
    Alternatively, you can type e.g. `plot(; type="scatter", kw...)`.


!!! note "Trace Chaining"
    PlotlyLight lets you *chain* traces with the dot syntax:
    ```@example
    using PlotlyLight  # hide
    y = randn(20)

    plot.bar(; y).scatter(; y)
    ```
