module PlotlyLight

using Artifacts: @artifact_str
using Dates
using REPL
using Random: RandomDevice

using OrderedCollections: OrderedDict
using EasyConfig: Config
using Cobweb: Cobweb, h, Node
using Base64: base64encode

#-----------------------------------------------------------------------------# exports
export Config, preset, Plot, plot

#-----------------------------------------------------------------------------# plotly.js artifact
# Paths are looked up when used rather than stored at precompile time, so they stay right if the depot moves
artifact(x...) = joinpath(artifact"plotly_artifacts", x...)

const PLOTLY_VERSION = VersionNumber(readchomp(artifact("version.txt")))
const PLOTLY_URL = "https://cdn.plot.ly/plotly-$PLOTLY_VERSION.min.js"
const SCHEMA_FILE = artifact("plot-schema.json")

const PLACEHOLDER = h.div(
    h.p("Loading PlotlyLight.jl plot..."),
    h.p("If this remains, PlotlyJS failed to load.", style="color:red")
)

const MATHJAX_URL = "https://cdn.jsdelivr.net/npm/mathjax@4/tex-mml-chtml.js"

#-----------------------------------------------------------------------------# Settings
Base.@kwdef mutable struct Settings
    div::Node           = h.div(; class="plotlylight-plot-div")
    layout::Config      = Config()
    config::Config      = Config(responsive=true, displaylogo=false)
    js_deps::OrderedDict{Symbol, String} = OrderedDict(:plotly => PLOTLY_URL)
    compress::Bool      = false
end
settings::Settings = Settings()

#-----------------------------------------------------------------------------# utils/other
function unknown_trace_msg(t)
    lc = Symbol(lowercase(string(t)))
    hint = haskey(Schema.traces, lc) ? "  Did you mean `$lc`?" : ""
    "`$t` is not a plotly.js trace type.$hint  See `keys(PlotlyLight.Schema.traces)`."
end

function check_attributes(type; kw...)
    t = Symbol(type)
    haskey(Schema.traces, t) || return @warn(unknown_trace_msg(t))
    attrs = Schema.traces[t][:attributes]
    foreach(k -> haskey(attrs, k) || @warn("`$t` does not have attribute `$k`."), keys(kw))
end

# `b` merged into `a`, recursing into nested dicts rather than replacing them.  `b`'s dicts are copied into `a`, so
# `a` never shares them with `b`.  (Other values, e.g. data arrays, are shared as usual.)
function deepmerge!(a::Config, b::AbstractDict)
    foreach(pairs(b)) do (k, v)
        old = get(a, k, nothing)
        a[k] = v isa AbstractDict ? deepmerge!(old isa Config ? old : Config(), v) : v
    end
    return a
end
deepmerge(a, b) = deepmerge!(deepmerge!(Config(), a), b)

trace_type(trace) = get(trace, :type, :scatter)

#-----------------------------------------------------------------------------# Plot
mutable struct Plot
    data::Vector{Config}
    layout::Config
    config::Config
    Plot(data::AbstractVector=Config[], layout = Config(), config = Config()) = new(Config.(data), Config(layout), Config(config))
    Plot(data, layout = Config(), config = Config()) = new([Config(data)], Config(layout), Config(config))
end

Base.:(==)(a::Plot, b::Plot) = all(getfield(a,f) == getfield(b,f) for f in fieldnames(Plot))

save(p::Plot, file::AbstractString) = open(io -> show(io, MIME("text/html"), html_page(p)), file, "w")
save(file::AbstractString, p::Plot) = save(p, file)

(p::Plot)(; kw...) = p(Config(kw))
(p::Plot)(data::Config) = (push!(p.data, data); return p)
(p::Plot)(p2::Plot) = merge!(p, p2)

function Base.getproperty(p::Plot, x::Symbol)
    x in fieldnames(Plot) && return getfield(p, x)
    haskey(Schema.traces, x) && return (; kw...) -> p(plot(; type=x, kw...))
    throw(ArgumentError("`Plot` has no property `$x`.  Can be `data`, `layout`, `config`, or a trace name."))
end
Base.propertynames(::Plot) = vcat(fieldnames(Plot)..., keys(Schema.traces)...)

# `b`'s traces and nested layout/config are copied, so later changes to `b` don't show up in `a`
function Base.merge!(a::Plot, b::Plot)
    append!(a.data, map(t -> deepmerge!(Config(), t), b.data))
    deepmerge!(a.layout, b.layout)
    deepmerge!(a.config, b.config)
    return a
end

function apply!(p::Plot, s::Settings)
    p.layout = deepmerge(s.layout, p.layout)
    p.config = deepmerge(s.config, p.config)
    return p
end
apply(p::Plot, s::Settings) = apply!(merge!(Plot(), p), s)

#------------------------------------------------------------------------------# includes
include("json.jl")
include("Schema.jl")

#-----------------------------------------------------------------------------# plot
function plot(; layout = Config(), config=Config(), type=:scatter, kw...)
    check_attributes(type; kw...)
    data = isempty(kw) ? Config[] : [Config(; type, kw...)]
    Plot(data, layout, config)
end

Base.propertynames(::typeof(plot)) = collect(keys(Schema.traces))

function Base.getproperty(::typeof(plot), type::Symbol)
    haskey(Schema.traces, type) || throw(ArgumentError(unknown_trace_msg(type)))
    return (; kw...) -> plot(; type, kw...)
end

#-----------------------------------------------------------------------------# NewPlot
# PlotlyLight representation of: <script>Plotly.newPlot("$id", $data, $layout, $config)</script>
struct NewPlot
    plot::Plot
    id::String
    sources::Vector{String}
end

function Base.show(io::IO, ::MIME"text/html", o::NewPlot)
    (; data, layout, config) = o.plot
    (; id, sources) = o
    print(io, """<script>(async () => {
        const div = document.getElementById("$id");
        try {
            const loaded = window.__plotlylight_scripts ??= {};
            await Promise.all($sources.map(src => loaded[src] ??= new Promise(resolve => {
                const s = document.createElement("script");
                s.src = src; s.async = false; s.onload = s.onerror = resolve;
                document.head.appendChild(s);
            })));
            if (!window.Plotly) throw new Error("Plotly isn't loaded on the page.");
            div.replaceChildren();
            await Plotly.newPlot(div,
        """)
    json_join(io, (data, layout, config), "", "")
    print(io, """);
        } catch (e) {
            div.replaceChildren(Object.assign(document.createElement("pre"),
                {textContent: "PlotlyLight couldn't draw this plot: " + e.message, style: "color:#c00; white-space:pre-wrap;"}));
        }
    })()</script>
    """)
end

#-----------------------------------------------------------------------------# display
# Random, from the OS's entropy rather than the global RNG: displaying a plot shouldn't change the user's random numbers
plot_id() = "plotlylight-" * join(rand(RandomDevice(), 'a':'z', 10))

# The plot's div and NewPlot (which loads the scripts)
function html_div(o::Plot, id=plot_id())
    h.div(class="plotlylight-parent",
        settings.div(PLACEHOLDER; id),
        NewPlot(apply(o, settings), id, collect(values(settings.js_deps)))
    )
end

# A standalone page whose plot fills the window.
function html_page(o::Plot, id=plot_id())
    page = h.html(
        h.head(
            h.meta(charset="utf-8"),
            h.meta(name="viewport", content="width=device-width, initial-scale=1"),
            h.meta(name="description", content="PlotlyLight.jl Plot"),
            h.title("PlotlyLight.jl"),
            h.style("html, body { padding: 0px; margin: 0px; } #$id { height: 100vh; }")
        ),
        h.body(html_div(o, id))
    )
    return HTML(io -> (print(io, "<!DOCTYPE html>"); show(io, MIME("text/html"), page)))
end

Base.show(io::IO, ::MIME"text/html", o::Plot) = show(io, MIME("text/html"), html_div(o))
Base.show(io::IO, ::MIME"juliavscode/html", o::Plot) = show(io, MIME("text/html"), o)

Base.show(io::IO, o::Plot) = print(io, "Plot(", join(trace_type.(o.data), ", "), ")")

function Base.show(io::IO, ::MIME"text/plain", o::Plot)
    n = length(o.data)
    print(io, "PlotlyLight.Plot with ", n, n == 1 ? " trace" : " traces")
    for (i, trace) in enumerate(o.data)
        attrs = filter(!=(:type), collect(keys(trace)))
        print(io, "\n  ", i, ". ", trace_type(trace), isempty(attrs) ? "" : ": " * join(attrs, ", "))
    end
end

Base.display(::REPL.REPLDisplay, o::Plot) = Cobweb.preview(html_page(o))

#-----------------------------------------------------------------------------# preset
# `preset_template_<X>` overwrites `settings.layout.template`
# `preset_src_<X>` replaces `settings.js_deps[:plotly]`
# `preset_display_<X>` overwrites `settings.config.responsive`, `settings.div`, `settings.layout.[width, height]`

# Templates are inserted verbatim (they're JSON already)
template!(t) = (settings.layout.template = RawJS(read(artifact("templates", "$t.json"), String)); nothing)

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
        none!       = () -> delete!(settings.js_deps, :plotly),
        cdn!        = () -> (settings.js_deps[:plotly] = PLOTLY_URL),
        local!      = () -> (settings.js_deps[:plotly] = artifact("plotly.min.js"))
    ),
    display = (
        fullscreen!     = () -> (settings.div.style = "height:100vh; width:100vw"),
        mathjax!        = () -> (settings.js_deps[:mathjax] = MATHJAX_URL; nothing),
    )
)

end  # PlotlyLight module
