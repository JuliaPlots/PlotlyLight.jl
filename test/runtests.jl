using PlotlyLight, Cobweb, Test, Aqua, Dates, Random
using PlotlyLight: settings, Plot, json

html(x) = repr("text/html", x)


#-----------------------------------------------------------------------------# json
@testset "json" begin
    @test json(1) == "1"
    @test json(1.0) == "1"  # whole numbers drop the `.0`
    @test json(1.5) == "1.5"
    @test json(1e20) == "1.0e20"  # too big for an Int64: stays a float
    @test json(-2.0^63) == "-9223372036854775808"
    @test json(1//2) == "0.5"
    @test json([1,2,3]) == "[1,2,3]"
    @test json([1.0,2.0,3.0]) == "[1,2,3]"
    @test json([1 2; 3 4]) == "[[1,2],[3,4]]"
    @test json((x=1,y=2)) == "{\"x\":1,\"y\":2}"
    @test json(nothing) == "null"
    @test json(true) == "true"
    @test json(false) == "false"
    @test json("test") == "\"test\""
    @test json(missing) == "null"
    @test json(NaN) == "null"
    @test json(Inf) == "null"
    @test json(-Inf) == "null"
    @test json(DateTime(2021,1,1)) == "\"2021-01-01T00:00:00\""
    # Strings are JS-escaped, and can't close the surrounding <script>
    @test json("say \"hi\"") == "\"say \\\"hi\\\"\""
    @test json("a\nb") == "\"a\\nb\""
    @test json("</script><br>") == "\"\\u003c/script\\u003e\\u003cbr\\u003e\""
    @test json("a & b") == "\"a \\u0026 b\""
    @test json(Dict("</script>" => 1)) == "{\"\\u003c/script\\u003e\":1}"
    @test json(:x) == "\"x\""
    # Nested values get the same treatment
    @test json([1.0, NaN, Inf]) == "[1,null,null]"
    @test json(Config(z = [1 2; 3 4], r = 1//2, s = "</script>")) == "{\"z\":[[1,2],[3,4]],\"r\":0.5,\"s\":\"\\u003c/script\\u003e\"}"
    @test json(reshape(1:8, 2, 2, 2)) == "[[[1,5],[3,7]],[[2,6],[4,8]]]"  # x[i][j][k] == x[i,j,k]
    @test json(π) == "3.141592653589793"
    @test json(DateTime(2021,1,1,0,0,0,5)) == "\"2021-01-01T00:00:00.005\""
    @test json(Date(2021,1,1)) == "\"2021-01-01\""
    @test json(skipmissing([1, missing])) == "[1]"
    @test json((1, 2)) == "[1,2]"
    @test json(Config(p = :a => 1)) == "{\"p\":{\"a\":1}}"
    @test json(Dict(1 => 2)) == "{\"1\":2}"
    # Unsupported types are an error, not a field-by-field object
    @test_throws ArgumentError json(1 + 2im)
    @test_throws ArgumentError json(Config(x = Some(1)))
end

@testset "JSTypedArray" begin
    ta(T, x) = json(PlotlyLight.JSTypedArray{T}(x))
    @test ta(Int8, [1, -1]) == "{\"dtype\":\"int8\",\"bdata\":\"Af8=\",\"shape\":\"2\"}"
    @test ta(Float32, [1.5, 2]) == "{\"dtype\":\"float32\",\"bdata\":\"AADAPwAAAEA=\",\"shape\":\"2\"}"
    @test ta(UInt8, [1 2; 3 4]) == "{\"dtype\":\"uint8\",\"bdata\":\"AQIDBA==\",\"shape\":\"2,2\"}"  # row-major
    @test ta(UInt8, reshape(1:8, 2, 2, 2)) == "{\"dtype\":\"uint8\",\"bdata\":\"AQUDBwIGBAg=\",\"shape\":\"2,2,2\"}"
    @test json(PlotlyLight.JSTypedArray(Float64[1, 2])) == "{\"dtype\":\"float64\",\"bdata\":\"AAAAAAAA8D8AAAAAAAAAQA==\",\"shape\":\"2\"}"
    # plotly.js has no 16-bit floats, 64-bit integers, or more than 3 dimensions
    @test_throws "no typed array of `Float16`" PlotlyLight.JSTypedArray{Float16}([1.0])
    @test_throws "no typed array of `Int64`" PlotlyLight.JSTypedArray([1])
    @test_throws "at most 3 dimensions" PlotlyLight.JSTypedArray{Float32}(zeros(1, 1, 1, 1))
end

@testset "compress" begin
    compress = PlotlyLight.compress
    cjson(x; kw...) = json(compress(x; min_length=0, kw...))
    dtype(x; kw...) = match(r"\"dtype\":\"(\w+)\"", cjson(Config(x=x); kw...))[1]

    # An object's numeric arrays become typed arrays, including in nested objects
    @test cjson([1, 2]) == json(PlotlyLight.JSTypedArray{UInt8}([1, 2]))
    @test cjson(Config(x=[1, 2])) == "{\"x\":$(cjson([1, 2]))}"
    @test cjson([Config(x=[1, 2])]) == "[$(cjson(Config(x=[1, 2])))]"
    @test cjson(Config(m=Config(color=[1, 2]))) == "{\"m\":$(cjson(Config(color=[1, 2])))}"
    @test cjson(Config(dims=[Config(values=[1, 2])])) == "{\"dims\":[$(cjson(Config(values=[1, 2])))]}"
    @test cjson((x=[1, 2],)) == cjson(Config(x=[1, 2]))
    @test cjson(:x => [1, 2]) == cjson(Config(x=[1, 2]))

    # Left as JSON: short arrays, Bools, strings, mixed types, and arrays inside arrays (plotly.js wouldn't decode them)
    @test json(compress(Config(x=1:3); min_length=4)) == "{\"x\":[1,2,3]}"
    @test cjson(Config(x=[true, false])) == "{\"x\":[true,false]}"
    @test cjson(Config(x=["a", "b"])) == "{\"x\":[\"a\",\"b\"]}"
    @test cjson(Config(x=Any["a", 1])) == "{\"x\":[\"a\",1]}"
    @test cjson(Config(z=[[1, 2], [3, 4]])) == "{\"z\":[[1,2],[3,4]]}"
    @test_throws MethodError compress([1, 2]; float_rtl=1e-5)  # typos aren't ignored

    # Smallest type that holds the data.  By default floats are only narrowed when it's exact.
    @test dtype([-1, 300]) == "int16"
    @test dtype(1:200) == "uint8"
    big = Int64(2)^40  # not `2^40`, which overflows where Int is Int32 (32-bit)
    @test dtype([0, big]) == "float32"  # no 64-bit integers, but these are exact as Float32
    @test dtype([big, big + 1000]) == "float64"
    @test dtype([1.0, 2.0, NaN, Inf]) == "float32"
    @test dtype(Float16[1, 2]) == "float32"
    @test dtype([0.1, 0.2]) == "float64"
    # With `float_rtol`, Float32 if its error is ≤ float_rtol of the data's range
    @test dtype([0.1, 0.2]; float_rtol=1e-5) == "float32"
    @test dtype(fill(0.1, 3); float_rtol=1e-5) == "float32"
    @test dtype(45 .+ range(0, 0.001, length=100); float_rtol=1e-5) == "float64"  # large offset, small range

    # Plots are compressed with the defaults when displayed, for arrays of at least 100
    @test occursin("\"bdata\"", html(plot.scatter(y=1:100)))
    @test !occursin("\"bdata\"", html(plot.scatter(y=1:99)))
    # ...and already-compressed plots are left as they are
    p = compress(plot.scatter(y=[0.1, 0.2]); min_length=0, float_rtol=1e-5)
    @test occursin("\"float32\"", html(p))

    # ranges=true: evenly spaced `x`/`y` become `x0`/`dx`, where plotly.js rebuilds exactly the same values
    trace(p; kw...) = only(compress(p; ranges=true, kw...).data)
    t = trace(plot.scatter(x=1:200, y=rand(200)))
    @test (t.x0, t.dx) == (1, 1) && !haskey(t, :x)
    @test !haskey(only(compress(plot.scatter(x=1:200, y=rand(200))).data), :x0)  # off by default
    t = trace(plot.scatter(x=rand(10), y=0:0.5:4.5))
    @test (t.y0, t.dy) == (0.0, 0.5) && !haskey(t, :y)
    t = trace(plot.scatter(x=1:10, y=1:10))  # not both: one has to give the number of points
    @test haskey(t, :x0) && haskey(t, :y) && !haskey(t, :y0)
    @test haskey(trace(plot.scatter(x=1:10, y=rand(5))), :x0)  # `x` would be cut to 5 points anyway
    @test haskey(trace(plot.scatter(x=1:5, y=rand(10))), :x)  # 10 points: `x0`/`dx` would add 5 more
    @test haskey(trace(plot.scatter(x=0:0.1:1, y=rand(11))), :x)  # 0 + 3 * 0.1 != 0.3
    @test haskey(trace(plot.scatter(x=1:10)), :x)  # nothing gives the number of points
    @test haskey(trace(plot.box(x=1:10, y=rand(10))), :x)  # box's x0/dx position whole boxes
    t = trace(plot.heatmap(x=1:4, y=10:10:30, z=rand(3, 4)))  # one per column/row of z
    @test (t.x0, t.dx, t.y0, t.dy) == (1, 1, 10, 10)
    @test haskey(trace(plot.heatmap(x=0:4, z=rand(3, 4))), :x)  # 5 cell edges, not centers
    @test haskey(trace(plot.heatmap(x=1:4, z=rand(3, 4), transpose=true)), :x)
    p = plot.scatter(x=1:10, y=rand(10))
    compress(p; ranges=true)
    @test haskey(p.data[1], :x)  # the plot itself is unchanged
end

#-----------------------------------------------------------------------------# Plot methods
@testset "compress_ranges!" begin
    c(; kw...) = PlotlyLight.compress_ranges!(Config(; kw...))
    th = collect(0.0:36:324)
    # polar: `r` becomes `r0`/`dr` (`theta` counts the points), and then `theta` can't be compressed too
    foreach((:scatterpolar, :scatterpolargl, :barpolar)) do type
        t = c(; type, r=1:10, theta=th)
        @test (t.r0, t.dr) == (1, 1) && !haskey(t, :r) && haskey(t, :theta)
    end
    # `theta` in degrees is built in radians, and only compressed if that gives exactly the same values
    rad = PlotlyLight.deg2rad_js
    @test haskey(c(type=:scatterpolar, r=rand(10), theta=th), :theta) == (map(i -> rad(0.0) + i * rad(36.0), 0:9) != rad.(th))
    @test !haskey(c(type=:scatterpolar, r=rand(10), theta=0:0.5:4.5, thetaunit="radians"), :theta)
    @test !haskey(c(type=:scatterpolar, r=1:10, theta=rand(5)), :r)  # `r` would be cut to 5 points anyway
    @test haskey(c(type=:scatterpolar, r=1:5, theta=rand(10)), :r)  # 10 points: `r0`/`dr` would add 5 more
    @test haskey(c(type=:scatterpolar, r=1:10), :r)  # nothing else to count the points
    # quiver works like scatter
    t = c(type=:quiver, x=1:5, y=rand(5), u=rand(5), v=rand(5))
    @test (t.x0, t.dx) == (1, 1) && !haskey(t, :x)
    # carpet/contourcarpet never build `a` from `a0`/`da`
    @test haskey(c(type=:carpet, a=1:5, b=1:5, y=rand(5, 5)), :a)
    @test haskey(c(type=:contourcarpet, a=1:5, b=1:5, z=rand(5, 5)), :a)
end

@testset "Plot methods" begin
    p = plot.scatter(x=1:10)
    @test p isa Plot
    @test plot(; x=1:10, type=:scatter) == p
    @test !occursin("Title", html(p))
    @test occursin("\"displaylogo\":false", html(p))

    p2 = Plot(Config(x = 1:10), Config(title="Title"))
    @test occursin("Title", html(p2))

    p3 = Plot(Config(x = 1:10), Config(title="Title"), Config(displaylogo=true))
    @test occursin("Title", html(p3))
    @test occursin("\"displaylogo\":true", html(p3))

    p4 = Plot();
    @test isempty(p4.data)
    @test p4(Config(x=1:10,y=1:10)) isa Plot
    @test length(p4.data) == 1
    p4(;x=1:10, y=1:10)
    @test length(p4.data) == 2
    @test p4.data[1] == p4.data[2]

    p5 = p(p2(p3(p4)))
    @test length(p5.data) == 5

    # Merged plots are copies: changing the source afterwards doesn't change the result
    a = plot.scatter(y=1:3)
    b = plot.bar(y=1:3, marker=Config(color="red"))
    b.layout.xaxis.title.text = "b"
    a.layout.xaxis.type = "log"
    a(b)
    b.data[1].name = "changed"
    b.data[1].marker.color = "blue"
    b.layout.xaxis.title.text = "changed"
    @test !haskey(a.data[2], :name)
    @test a.data[2].marker.color == "red"
    @test a.layout.xaxis == Config(type="log", title=Config(text="b"))  # nested layout is merged, not replaced

    # Typos are errors naming the problem, not a closure or KeyError
    @test_throws "has no field `lyout`" p.lyout
    @test_throws "`lines` is not a plotly.js trace type" p.lines
end

@testset "plot" begin
    @test_warn "`scatter` does not have attribute `X`" plot.scatter(X=1:10);
    @test_nowarn plot.scatter(x=1:10);
    @test contains(json(plot(y=1:10).data), "scatter")
    @test_throws "`lines` is not a plotly.js trace type" plot.lines
    @test_warn "Did you mean `scatter`?" plot(type="Scatter", y=1:3)
    @test_warn "`foo` is not a plotly.js trace type" plot(type=:foo)
end

@testset "settings defaults are merged recursively" begin
    PlotlyLight.with_settings(layout=Config(xaxis=Config(showgrid=false)), config=Config(toImageButtonOptions=Config(format="svg"))) do s
        p = plot.scatter(y=1:3)
        p.layout.xaxis.title.text = "X"
        p.config.toImageButtonOptions.scale = 2
        out = html(p)
        @test occursin("\"xaxis\":{\"showgrid\":false,\"title\":{\"text\":\"X\"}}", out)
        @test occursin("\"toImageButtonOptions\":{\"format\":\"svg\",\"scale\":2}", out)
        @test s.layout == Config(xaxis=Config(showgrid=false))  # settings are untouched
    end
end

@testset "settings" begin
    @test PlotlyLight.settings.layout == Config()
    @test PlotlyLight.settings.config == Config(; responsive=true, displaylogo=false)
end

@testset "saving" begin
    dir = mktempdir()
    path1 = joinpath(dir, "test.html")
    path2 = joinpath(dir, "test2.html")
    p = Plot(Config(x = 1:10))
    PlotlyLight.save(p, path1)
    PlotlyLight.save(path2, p)
    @test isfile(path1)
    @test isfile(path2)
end

@testset "other" begin
    @test propertynames(Plot()) isa Vector{Symbol}
    @test all(x in propertynames(Plot()) for x in propertynames(plot))
end

@testset "show/display" begin
    p = plot.scatter(x=1:3, y=1:3)(plot.bar(y=1:3))
    @test repr(p) == "Plot(scatter, bar)"
    @test repr(Plot()) == "Plot()"
    @test repr("text/plain", p) == "PlotlyLight.Plot with 2 traces\n  1. scatter: x, y\n  2. bar: y"
    Random.seed!(1); a = rand(); Random.seed!(1); html(p); b = rand()
    @test a == b  # displaying a plot doesn't consume the global RNG
    @test allunique([PlotlyLight.plot_id() for _ in 1:10_000])
    @test repr("text/plain", Plot()) == "PlotlyLight.Plot with 0 traces"

    # External scripts are loaded once per page by the plot's script, not a `<script src>` per plot
    s = html(p)
    @test !occursin("<script src", s)
    # The div explains itself until the plot draws, and failures replace it with the reason
    @test occursin("class=\"plotlylight-fallback\"", s)
    @test occursin("PlotlyLight couldn't draw this plot: ", s)
    @test occursin("\"$(PlotlyLight.PLOTLY_URL)\"", s)
    # Full pages (save, REPL) work the same way
    @test !occursin("<script src", html(PlotlyLight.html_page(p)))
    @test occursin("[\"$(PlotlyLight.PLOTLY_URL)\"]", html(PlotlyLight.html_page(p)))

    s = sprint((io, x) -> show(io, MIME("juliavscode/html"), x), Plot())
end

@testset "preset" begin
    foreach((:template, :source)) do g
        group = getproperty(preset, g)
        foreach(name -> @test(isnothing(getproperty(group, name)())), propertynames(group))
    end
    preset.source.local!()
    @test settings.js_deps[:plotly] == PlotlyLight.artifact("plotly.min.js")
    preset.source.none!()
    @test isempty(settings.js_deps)
    preset.display.mathjax!()
    preset.source.cdn!()
    @test collect(settings.js_deps) == [:plotly => PlotlyLight.PLOTLY_URL, :mathjax => PlotlyLight.MATHJAX_URL]  # plotly.js first
    delete!(settings.js_deps, :mathjax)
    preset.template.none!()

    # Discoverable: tab completion (propertynames) and display list every preset
    @test propertynames(preset) == [:display, :source, :template]
    @test :plotly_dark! in propertynames(preset.template)
    @test occursin("template: ggplot2!, ", repr("text/plain", preset))
    @test repr(preset.template.ggplot2!) == "preset.template.ggplot2!"
    @test_throws "There's no `preset.tempalte`" preset.tempalte
    @test_throws "There's no `preset.template.ggplto2!`" preset.template.ggplto2!

    # Other modules can add presets, and groups
    @eval module PresetExtension
        import PlotlyLight
        PlotlyLight.preset!(::Val{:template}, ::Val{:big_font}) =
            (PlotlyLight.settings.layout.template = PlotlyLight.Config(layout=(; font=(; size=20))); nothing)
        PlotlyLight.preset!(::Val{:extra}, ::Val{:echo}, x) = x
    end
    @test :big_font! in propertynames(preset.template)
    @test preset.extra.echo!(1) == 1
    preset.template.big_font!()
    @test occursin("\"font\":{\"size\":20}", html(plot.scatter(y=1:3)))
    preset.template.none!()
end

#-----------------------------------------------------------------------------# browser
include("browser.jl")

#-----------------------------------------------------------------------------# Aqua
Aqua.test_all(PlotlyLight,
    deps_compat=(; ignore =[:REPL, :Random], check_extras = (;ignore=[:Test])),
    persistent_tasks = false
)
