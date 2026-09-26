module PlotlyLight

using Artifacts: @artifact_str
using Base64
using Downloads: download
using Dates
using REPL
using Random: RandomDevice

using JSON: JSON
using EasyConfig: Config
using Cobweb: Cobweb, h, IFrame, Node
using Zlib_jll: libz

#-----------------------------------------------------------------------------# exports
export Config, preset, Plot, plot

artifact(x...) = joinpath(artifact"plotly_artifacts", x...)

#-----------------------------------------------------------------------------# plotly::PlotlyArtifacts
Base.@kwdef struct PlotlyArtifacts
    version::VersionNumber  = VersionNumber(read(artifact("version.txt"), String))
    url::String             = "https://cdn.plot.ly/plotly-$version.min.js"
    path::String            = artifact("plotly.min.js")
    schema::JSON.Object{String, Any} = JSON.parsefile(artifact("plot-schema.json"))
    templates::Dict{String,String} = Dict(t => artifact("templates", t) for t in readdir(artifact("templates")))
end
Base.show(io::IO, p::PlotlyArtifacts) = print(io, "PlotlyArtifacts: v$(p.version)")
plotly::PlotlyArtifacts = PlotlyArtifacts()

#-----------------------------------------------------------------------------# Settings
Base.@kwdef mutable struct Compression
    on::Bool = false
    min_length::Int = 100
    float_types::Tuple = (Float64, Float32, Float16)  # candidates for float compression
    rtol::Float64 = 1e-5  # criteria for dropping to smaller float
end

Base.@kwdef mutable struct Settings
    src::Node               = h.script(src=plotly.url, charset="utf-8")
    div::Node               = h.div(; class="plotlylight-plot-div")
    layout::Config          = Config()
    config::Config          = Config(responsive=true, displaylogo=false)
    reuse_preview::Bool     = true
    page_css::Cobweb.Node   = h.style("html, body { padding: 0px; margin: 0px; }")
    use_iframe::Bool        = false
    iframe_style            = "display:block; border:none; min-height:350px; min-width:350px; width:100%; height:100%"
    src_inject::Vector      = []
    compression::Compression = Compression()
end
settings::Settings = Settings()

function Settings(s::Settings; kw...)
    s2 = deepcopy(s)
    for (k, v) in kw
        setfield!(s2, k, v)
    end
    return s2
end

function with_settings(f; kw...)
    old = settings
    try
        global settings = Settings(settings; kw...)
        f(settings)
    finally
        global settings = old
    end
end

#------------------------------------------------------------------------------# json.jl
include("json.jl")

#-----------------------------------------------------------------------------# utils/other
attributes(t::Symbol) = plotly.schema.traces[t].attributes
check_attribute(trace, attr::Symbol) = haskey(attributes(Symbol(trace)), attr) || @warn("`$trace` does not have attribute `$attr`.")
check_attributes(trace; kw...) = foreach(k -> check_attribute(Symbol(trace), k), keys(kw))

#-----------------------------------------------------------------------------# Plot
mutable struct Plot
    data::Vector{Config}
    layout::Config
    config::Config
    Plot(data::AbstractVector=Config[], layout = Config(), config = Config()) = new(Config.(data), Config(layout), Config(config))
    Plot(data, layout = Config(), config = Config()) = new([Config(data)], Config(layout), Config(config))
end

Base.:(==)(a::Plot, b::Plot) = all(getfield(a,f) == getfield(b,f) for f in fieldnames(Plot))

save(p::Plot, file::AbstractString) = open(io -> print(io, html_page(p)), file, "w")
save(file::AbstractString, p::Plot) = save(p, file)

(p::Plot)(; kw...) = p(Config(kw))
(p::Plot)(data::Config) = (push!(p.data, data); return p)
(p::Plot)(p2::Plot) = merge!(p, p2)

Base.getproperty(p::Plot, x::Symbol) = x in fieldnames(Plot) ? getfield(p, x) : (; kw...) -> p(plot(; type=x, kw...))
Base.propertynames(::Plot) = vcat(fieldnames(Plot)..., Symbol.(keys(plotly.schema.traces))...)

Base.merge!(a::Plot, b::Plot) = (append!(a.data, b.data); merge!(a.layout, b.layout); merge!(a.config, b.config); a)

#-----------------------------------------------------------------------------# plot
function plot(; layout = Config(), config=Config(), type=:scatter, kw...)
    check_attributes(type; kw...)
    data = isempty(kw) ? Config[] : [Config(; type, kw...)]
    Plot(data, layout, config)
end
Base.propertynames(::typeof(plot)) = Symbol.(keys(plotly.schema.traces))
Base.getproperty(::typeof(plot), type::Symbol) = (; kw...) -> plot(; type=type, kw...)


#-----------------------------------------------------------------------------# NewPlotScript
# <script> that starts loading `srcs` (once per page, in order), records promises in `window.__plotlylight_scripts`.
load_scripts(srcs) = h.script("""(srcs => {
    const loaded = window.__plotlylight_scripts || (window.__plotlylight_scripts = {});
    const failed = window.__plotlylight_failed || (window.__plotlylight_failed = []);
    for (const src of srcs) loaded[src] = loaded[src] || new Promise(resolve => {
        const s = document.createElement("script");
        s.src = src; s.async = false; s.onload = resolve;
        s.onerror = () => { failed.push(src); resolve(); };
        document.head.appendChild(s);
    });
})($(JSON.json(srcs)))""")

# Static content of the plot's div, replaced once the plot draws
plot_fallback() = h.p("Loading plot…  If this message stays, JavaScript didn't run here (e.g. an untrusted notebook).";
    class="plotlylight-fallback", style="font-family:sans-serif; color:#888;")

# PlotlyLight representation of: <script>Plotly.newPlot("$id", $data, $layout, $config)</script>
struct NewPlotScript
    plot::Plot
    settings::Settings
    id::String
end
function Base.show(io::IO, ::MIME"text/html", o::NewPlotScript)
    layout = merge(o.settings.layout, o.plot.layout)
    config = merge(o.settings.config, o.plot.config)
    c = o.settings.compression
    jsonio = c.on ? IOContext(io, :plotlylight_compression => c) : io
    print(io, """<script>(async () => {
    const div = document.getElementById("$(o.id)");
    try {
        await Promise.all(Object.values(window.__plotlylight_scripts || {}));
        if (typeof Plotly === "undefined") {
            const failed = window.__plotlylight_failed || [];
            throw new Error("plotly.js didn't load" + (failed.length ? " (failed: " + failed.join(", ") + ")" : "") +
                ".  If you're offline, try `PlotlyLight.preset.source.standalone!()`.");
        }
        div.replaceChildren();
        await Plotly.newPlot(div, """)
    json(jsonio, o.plot.data); print(io, ',')
    json(jsonio, layout); print(io, ',')
    json(jsonio, config)
    print(io, """);
    } catch (e) {
        div.replaceChildren(Object.assign(document.createElement("pre"),
            {textContent: "PlotlyLight couldn't draw this plot: " + e.message, style: "color:#c00; white-space:pre-wrap;"}));
    }
})()</script>""")
end

#-----------------------------------------------------------------------------# display
# From the OS's entropy, not the global RNG: displaying a plot shouldn't change the user's random numbers
rand_id() = "plotlylight-" * join(rand(RandomDevice(), 'a':'z', 10))

# `src` of a `<script src=...>` Node, otherwise `nothing`
script_src(x) = x isa Node && Cobweb.tag(x) == :script ? get(Cobweb.attrs(x), :src, nothing) : nothing

# Scripts every plot needs: `settings.src_inject`, compression decoders (if on), and plotly.js
page_scripts(s::Settings) = [s.src_inject..., (s.compression.on ? (COMPRESSION_SRC,) : ())..., s.src]

# External scripts are loaded once per page by `load_scripts`; everything else is included as-is.
function html_div(o::Plot, id=rand_id())
    scripts = page_scripts(settings)
    srcs = filter(!isnothing, script_src.(scripts))
    inline = filter(x -> isnothing(script_src(x)), scripts)
    loader = isempty(srcs) ? () : (load_scripts(srcs),)
    h.div(class="plotlylight-parent", inline..., loader..., settings.div(plot_fallback(); id), NewPlotScript(o, settings, id))
end

function html_page(o::Plot, id=rand_id())
    h.html(
        h.head(
            h.meta(charset="utf-8"),
            h.meta(name="viewport", content="width=device-width, initial-scale=1"),
            h.meta(name="description", content="PlotlyLight.jl Plot"),
            h.title("PlotlyLight.jl"),
            settings.page_css,
            page_scripts(settings)...
        ),
        h.body(h.div(class="plotlylight-parent", settings.div(plot_fallback(); id), NewPlotScript(o, settings, id)))
    )
end

function html_iframe(o::Plot, id=rand_id(), kw...)
    with_settings() do s
        s.div.style = "height:100vh; width:100vw"
        Cobweb.IFrame(html_page(o, id); style=s.iframe_style, kw...)
    end
end

function Base.show(io::IO, ::MIME"text/html", o::Plot)
    (get(io, :jupyter, false) || settings.use_iframe) ?
        show(io, MIME("text/html"), html_iframe(o)) :
        show(io, MIME("text/html"), html_div(o))
end
Base.show(io::IO, ::MIME"juliavscode/html", o::Plot) = show(io, MIME("text/html"), o)
trace_type(trace) = get(trace, :type, :scatter)  # plotly.js defaults to scatter

Base.show(io::IO, o::Plot) = print(io, "Plot(", join(trace_type.(o.data), ", "), ")")

function Base.show(io::IO, ::MIME"text/plain", o::Plot)
    n = length(o.data)
    print(io, "PlotlyLight.Plot with ", n, n == 1 ? " trace" : " traces")
    for (i, trace) in enumerate(o.data)
        attrs = filter(!=(:type), collect(keys(trace)))
        print(io, "\n  ", i, ". ", trace_type(trace), isempty(attrs) ? "" : ": " * join(attrs, ", "))
    end
end

Base.display(::REPL.REPLDisplay, o::Plot) = Cobweb.preview(html_page(o); reuse=settings.reuse_preview)


#-----------------------------------------------------------------------------# preset
# `preset_template_<X>` overwrites `settings.layout.template`
# `preset_src_<X>` overwrites `settings.src`
# `preset_display_<X>` overwrites `settings.config.responsive`, `settings.div`, `settings.layout.[width, height]`

template!(t) = (settings.layout.template = JSON.parsefile(plotly.templates["$t.json"]); nothing)

preset = (
    template = (
        none!           = () -> (haskey(settings.layout, :template) && delete!(settings.layout, :template); nothing),
        ggplot2!        = () -> template!(:ggplot2),
        gridon!         = () -> template!(:gridon),
        plotly!         = () -> template!(:plotly),
        plotly_dark!    = () -> template!(:plotly_dark),
        plotly_white!   = () -> template!(:plotly_white),
        presentation!   = () -> template!(:presentation),
        seaborn!        = () -> template!(:seaborn),
        simple_white!   = () -> template!(:simple_white),
        xgridoff!       = () -> template!(:xgridoff),
        ygridoff!       = () -> template!(:ygridoff)
    ),
    source = (
        none!       = () -> (settings.src = h.div("No script due to `PlotlyLight.src_none!`", style="display:none;"); nothing),
        cdn!        = () -> (settings.src = h.script(src=plotly.url, charset="utf-8"); nothing),
        local!      = () -> (settings.src = h.script(src=plotly.path, charset="utf-8"); nothing),
        standalone! = () -> (settings.src = h.script(read(plotly.path, String), charset="utf-8"); nothing)
    ),
    display = (
        fullscreen!     = () -> (settings.div.style = "height:100vh; width:100vw"),
        mathjax!        = () -> (push!(settings.src_inject, h.script(src="https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-svg.js"))),
        compress!       = (on=true) -> (settings.compression.on = on)
    )
)

end  # PlotlyLight module
