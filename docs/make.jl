using Documenter
using PlotlyLight

# PlotlyLight.settings.use_iframe = true

makedocs(
    sitename = "PlotlyLight",
    modules = [PlotlyLight],
    format = Documenter.HTML(),
    pages = [
        "index.md",
        "plotly_basics.md",
        "templates.md",
        "saving.md",
        "source.md",
        "settings.md",
    ]
)


deploydocs(
    repo = "github.com/JuliaPlots/PlotlyLight.jl.git",
    push_preview = true
)
