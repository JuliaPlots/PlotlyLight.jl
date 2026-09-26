using PlotlyLight, Cobweb, Test, Aqua, Dates, JSON, Random
using PlotlyLight: settings, Plot, json

html(x) = repr("text/html", x)

#-----------------------------------------------------------------------------# json
@testset "json" begin
    @test json(1) == "1"
    @test json(1.0) == "1.0"
    @test json(1//2) == "0.5"
    @test json([1,2,3]) == "[1,2,3]"
    @test json([1.0,2.0,3.0]) == "[1.0,2.0,3.0]"
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
    @test json(DateTime(2021,1,1)) == "\"2021-01-01 00:00:00\""
    # Strings are JS-escaped, and can't close the surrounding <script>
    @test json("say \"hi\"") == "\"say \\\"hi\\\"\""
    @test json("a\nb") == "\"a\\nb\""
    @test json("</script><br>") == "\"\\u003c/script>\\u003cbr>\""
    @test json(:x) == "\"x\""
end

@testset "compression" begin
    c = PlotlyLight.Compression(on=true, min_length=0)
    cjson(x, c=c) = sprint(json, x; context = :plotlylight_compression => c)
    @test cjson(Int[1, 2]) == "await numArrFromBase64(Uint8Array,'eJxjZAIAAAYABA==',2)"
    @test cjson(Int[1 2; 3 4]) == "await numArrFromBase64(Uint8Array,'eJxjZGJmAQAAGAAL',2,2)"
    @test cjson(Float64[1, 2]) == "await numArrFromBase64(Float16Array,'eJxjsGFwAAAA+AB9',2)"
    @test cjson(Float64[1 2; 3 4]) == "await numArrFromBase64(Float16Array,'eJxjsGFwYHBicAEAA/YBAw==',2,2)"
    @test cjson(["a", "b"]) == "await strVecFromBase64('eJyLVkpU0lFKUooFAArqAjA=')"  # zlib of `["a","b"]`

    # Left as plain JSON: short arrays, Bools, mixed types.  Containers recurse.
    @test cjson(1:3, PlotlyLight.Compression(on=true, min_length=4)) == "[1,2,3]"
    @test cjson([true, false]) == "[true,false]"
    @test cjson(Any["a", 1]) == "[\"a\",1]"
    @test cjson(Config(x = [1, 2], name = "a")) == "{\"x\":$(cjson([1, 2])),\"name\":\"a\"}"
    @test cjson(([1, 2],)) == "[$(cjson([1, 2]))]"
    @test json([1, 2]) == "[1,2]"  # no compression without the IOContext setting

    # Smallest JS type whose error is ≤ rtol of the data's range.  JS has no Int64 typed array.
    type(x, c=c) = PlotlyLight._compressed_json_type(x, c)
    @test type([1.0, 2.0, NaN, Inf]) == Float16
    @test type(range(0, 1, length=100)) == Float32
    @test type(45 .+ range(0, 0.001, length=100)) == Float64  # large offset, small range
    @test type([1e5, 2e5]) == Float32  # beyond floatmax(Float16)
    @test type(fill(0.1, 3)) == Float32
    @test type(rand(Float32, 10)) == Float32
    @test type([1.0, 2.0], PlotlyLight.Compression(float_types=(Float64, Float32))) == Float32
    @test type([-1, 300]) == Int16
    big = Int64(2)^40  # not `2^40`, which overflows where Int is Int32 (32-bit)
    @test type([0, big]) == Float32
    @test type([big, big + 1000]) == Float64

    # Decoders are on the page exactly once when compression is on, however it was turned on
    decoders(x) = count(r"<script>\s*window.base64ToBytes", html(x))
    preset.display.compress!(true); preset.display.compress!(true)
    @test settings.compression.on
    @test decoders(plot.scatter(y=1:3)) == 1
    @test decoders(PlotlyLight.html_page(plot.scatter(y=1:3))) == 1
    preset.display.compress!(false)
    @test decoders(plot.scatter(y=1:3)) == 0
    PlotlyLight.with_settings(compression = PlotlyLight.Compression(on=true)) do _
        @test decoders(plot.scatter(y=1:3)) == 1
    end
    preset.display.compress!(true)
    @test occursin("await numArrFromBase64(", html(plot.scatter(y=1:100)))
end

#-----------------------------------------------------------------------------# Plot methods
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
end

@testset "plot" begin
    @test_warn "`scatter` does not have attribute `X`" plot.scatter(X=1:10);
    @test_nowarn plot.scatter(x=1:10);
    @test contains(JSON.json(plot(y=1:10)), "scatter")
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
    @test collect(propertynames(JSON.parse(JSON.json(Plot())))) == [:data, :layout, :config]
end

@testset "show/display" begin
    p = plot.scatter(x=1:3, y=1:3)(plot.bar(y=1:3))
    @test repr(p) == "Plot(scatter, bar)"
    @test repr(Plot()) == "Plot()"
    @test repr("text/plain", p) == "PlotlyLight.Plot with 2 traces\n  1. scatter: x, y\n  2. bar: y"
    Random.seed!(1); a = rand(); Random.seed!(1); html(p); b = rand()
    @test a == b  # displaying a plot doesn't consume the global RNG
    @test repr("text/plain", Plot()) == "PlotlyLight.Plot with 0 traces"

    # External scripts are loaded once per page by the plot's script, not a `<script src>` per plot
    s = html(p)
    @test !occursin("<script src", s)
    # The div explains itself until the plot draws, and failures replace it with the reason
    @test occursin("class=\"plotlylight-fallback\"", s)
    @test occursin("PlotlyLight couldn't draw this plot: ", s)
    @test occursin("\"$(PlotlyLight.plotly.url)\"", s)
    # ...but full pages (save, REPL, Jupyter iframe) load them in <head>
    @test occursin("<script src=\"$(PlotlyLight.plotly.url)\"", html(PlotlyLight.html_page(p)))
    @test occursin("<iframe", sprint((io, x) -> show(IOContext(io, :jupyter => true), MIME("text/html"), x), p))
    # Inline sources (e.g. `standalone!`) are included as-is and plot immediately
    PlotlyLight.with_settings(src = h.script("/* plotly.js */")) do _
        s = html(p)
        @test occursin("<script>/* plotly.js */</script>", s)
        @test !occursin("\"$(PlotlyLight.plotly.url)\"", s)
    end

    s = sprint((io, x) -> show(io, MIME("juliavscode/html"), x), Plot())
end

@testset "preset" begin
    for f in PlotlyLight.preset.template
        f()
    end
    for f in PlotlyLight.preset.source
        f()
    end
end

#-----------------------------------------------------------------------------# Aqua
Aqua.test_all(PlotlyLight,
    deps_compat=(; ignore =[:REPL, :Random], check_extras = (;ignore=[:Test])),
    persistent_tasks = false
)
