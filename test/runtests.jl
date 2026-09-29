using PlotlyLight, Cobweb, Test, Aqua, Dates, Random, JSON, Base64
using PlotlyLight: settings, Plot, json

html(x) = repr("text/html", x)

# `f()` with `settings` replaced by `Settings(; kw...)`, restored afterwards
function with_settings(f; kw...)
    old = PlotlyLight.settings
    PlotlyLight.settings = PlotlyLight.Settings(; kw...)
    try
        f()
    finally
        PlotlyLight.settings = old
    end
end


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

@testset "TypedArray" begin
    ta(x) = json(TypedArray(x))
    # Written in the smallest type plotly.js can decode that holds every value exactly
    @test ta([1, -1]) == "{\"bdata\":\"Af8=\",\"dtype\":\"int8\",\"shape\":\"2\"}"
    @test ta([1.5, 2]) == "{\"bdata\":\"AADAPwAAAEA=\",\"dtype\":\"float32\",\"shape\":\"2\"}"
    @test ta([1 2; 3 4]) == "{\"bdata\":\"AQIDBA==\",\"dtype\":\"uint8\",\"shape\":\"2,2\"}"  # row-major
    @test ta([0.1, 0.2]) == "{\"bdata\":\"mpmZmZmZuT+amZmZmZnJPw==\",\"dtype\":\"float64\",\"shape\":\"2\"}"
    @test ta(reshape(1:8, 2, 2, 2)) == "{\"bdata\":\"AQUDBwIGBAg=\",\"dtype\":\"uint8\",\"shape\":\"2,2,2\"}"
    @test ta([1, -1]) == json(typed_array([1, -1]))
    @test occursin("\"y\":{\"bdata\":\"AQID\"", html(plot.scatter(y=TypedArray(1:3))))
    # Tolerances allow Float32
    @test occursin("\"float32\"", json(TypedArray([0.1, 0.2], 1e-5)))
    @test occursin("\"float32\"", json(TypedArray([0.1, 0.2], 0.0, 1e-5)))
    # Arrays plotly.js can't decode as typed arrays stay JSON
    @test ta([true, false]) == "[true,false]"
    @test ta(Int[]) == "[]"
    @test ta(["a", "b"]) == "[\"a\",\"b\"]"
    @test ta([1, missing]) == "[1,null]"
    @test ta(zeros(1, 1, 1, 1)) == "[[[[0]]]]"

    min_type = PlotlyLight.min_type
    @test min_type([-1, 300]) == Int16
    @test min_type(1:200) == UInt8
    big = Int64(2)^40  # not `2^40`, which overflows where Int is Int32 (32-bit)
    @test min_type([0, big]) == Float32  # no 64-bit integers, but these are exact as Float32
    @test min_type([big, big + 1000]) == Float64
    @test min_type([1.0, 2.0, NaN, Inf]) == Float32
    @test min_type(Float16[0.5, 1.5]) == Float32  # no Float16
    @test min_type([0.1, 0.2]) == Float64
    # With a tolerance, Float32 if it's within `rtol`/`atol` of every value
    @test min_type([0.1, 0.2]; rtol=1e-5) == Float32
    @test min_type([0.1, 0.2]; atol=1e-5) == Float32
end

@testset "Compressed" begin
    # The bytes inside the JS expression, decompressed in Julia
    function decompressed(js)
        bytes = base64decode(match(r"\)\(\"([A-Za-z0-9+/=]+)\"\)\)", js)[1])  # `)("<base64>"))`
        out = Vector{UInt8}(undef, 10^6)
        n = Ref{Culong}(length(out))
        ret = ccall((:uncompress, PlotlyLight.libz), Cint, (Ptr{UInt8}, Ref{Culong}, Ptr{UInt8}, Culong), out, n, bytes, length(bytes))
        ret == 0 || error("zlib's `uncompress` failed with code $ret")
        resize!(out, n[])
    end

    # Numeric arrays: JS typed arrays of their own eltype, or (e.g. Int64) the smallest DTYPE that holds them
    js = json(Compressed(repeat([1.5, 2.5], 1000)))
    @test occursin("new DecompressionStream(\"deflate\")", js) && occursin("new Float64Array(", js)
    @test sizeof(js) < sizeof(json(repeat([1.5, 2.5], 1000))) / 10
    @test reinterpret(Float64, decompressed(js)) == repeat([1.5, 2.5], 1000)
    @test reinterpret(Float64, decompressed(json(Compressed([0.1, 0.2]; level=0)))) == [0.1, 0.2]  # level 0: stored
    @test occursin("new Float16Array(", json(Compressed(Float16[0.5])))
    @test occursin("new Float32Array(", json(Compressed(Float32[0.5])))
    js = json(Compressed([-1, 300]))
    @test occursin("new Int16Array(", js) && reinterpret(Int16, decompressed(js)) == [-1, 300]
    # Matrices and 3-d arrays: row-major, nested into rows
    z = [1 2 3; 4 5 6]
    js = json(Compressed(z))
    @test occursin("return rows(x, [2,3]);", js) && decompressed(js) == vec(permutedims(z))
    a = reshape(1:8, 2, 2, 2)
    js = json(Compressed(a))
    @test occursin("return rows(x, [2,2,2]);", js) && decompressed(js) == vec(permutedims(a, (3, 2, 1)))
    @test occursin(".arrayBuffer()", html(plot.scatter(y=Compressed(zeros(1000)))))
    # Numbers with gaps (`missing`/`nothing`): NaN in a Float32Array (where every other value fits) or Float64Array
    js = json(Compressed([1.0, missing, 3.0]))
    @test occursin("new Float32Array(", js) && isequal(reinterpret(Float32, decompressed(js)), Float32[1, NaN, 3])
    js = json(Compressed([0.1, nothing]))
    @test occursin("new Float64Array(", js) && isequal(reinterpret(Float64, decompressed(js)), [0.1, NaN])
    @test occursin("new Float64Array(", json(Compressed([Int64(2)^40 + 1, missing])))
    js = json(Compressed(Union{Missing, Int}[1 2; missing 4]))
    @test occursin("return rows(x, [2,2]);", js) && isequal(reinterpret(Float32, decompressed(js)), Float32[1, 2, NaN, 4])
    @test String(decompressed(json(Compressed(Union{Missing, Bool}[true, missing])))) == "[true,null]"  # Bools stay Bools
    @test String(decompressed(json(Compressed([missing, missing])))) == "[null,null]"
    # Bools: one byte each, read back as JS `true`/`false`
    js = json(Compressed([true, false, true]))
    @test occursin("v => v === 1", js) && decompressed(js) == [1, 0, 1]
    @test decompressed(json(Compressed(trues(3)))) == [1, 1, 1]  # BitArray
    js = json(Compressed([true false false; false true true]))
    @test occursin("x.slice(", js) && occursin("return rows(x, [2,3]);", js) && decompressed(js) == [1, 0, 0, 0, 1, 1]

    # Everything else: JSON
    x = Config(y = repeat([1.5, 2.5], 1000), text = fill("</script>", 1000))
    js = json(Compressed(x))
    @test occursin(".json()", js)
    @test sizeof(js) < sizeof(json(x)) / 10
    @test String(decompressed(js)) == json(x)
    @test String(decompressed(json(Compressed(["a", "b"])))) == "[\"a\",\"b\"]"
    @test String(decompressed(json(Compressed(Int[])))) == "[]"
    @test Compressed([1.0]) isa Compressed{Vector{Float64}}
    @test Compressed(1).level == 6
    @test_throws "level must be 0 to 9" Compressed(1; level=10)
end

@testset "settings.compression" begin
    @test settings.compression == (level=0, rtol=0.0, atol=0.0, n=1000)
    @test !occursin("DecompressionStream", html(plot.scatter(y=rand(5000))))  # off by default
    p = plot.scatter(x=1:200, y=rand(50), text=fill("a", 200), marker=Config(color=1:200))
    with_settings(compression=(level=6, rtol=0.0, atol=0.0, n=100)) do
        s = html(p)
        @test count("DecompressionStream", s) == 3  # x, text, and marker.color
        @test occursin("new Uint8Array(", s) && occursin(".json()", s)
        @test occursin("\"y\":[", s)  # fewer than n elements
        @test occursin("new Float64Array(", html(plot.scatter(y=rand(200))))
    end
    @test p.data[1].x isa Vector{Int} && p.data[1].marker.color isa Vector{Int}  # the plot itself is unchanged
    # Tolerances are passed to `min_type`, for automatic and explicit `Compressed`
    with_settings(compression=(level=6, rtol=1e-5, atol=0.0, n=100)) do
        @test occursin("new Float32Array(", html(plot.scatter(y=rand(200))))
        @test occursin("new Float32Array(", json(Compressed([Int64(2)^40 + 1, 0])))
        @test occursin("new Float32Array(", json(Compressed([0.1, missing])))
    end
    with_settings(compression=(level=6, rtol=0.0, atol=0.0, n=100)) do
        @test occursin("new Float64Array(", html(plot.scatter(y=[missing; rand(199)])))  # arrays with gaps too
    end
    @test occursin("new Float64Array(", json(Compressed([Int64(2)^40 + 1, 0])))
    with_settings(compression=(level=0, rtol=0.0, atol=0.0, n=1)) do
        @test !occursin("DecompressionStream", html(p))  # level 0: off
    end
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
    @test_throws "`Plot` has no property `lyout`" p.lyout
    @test_throws "`Plot` has no property `lines`" p.lines
end

@testset "plot" begin
    @test_nowarn plot.scatter(x=1:10);
    @test contains(json(plot(y=1:10).data), "scatter")
    @test_throws "`lines` is not a plotly.js trace type" plot.lines
    @test_warn "`scatter` does not have attribute `X`" PlotlyLight.check_attributes(:scatter; X=1:10)
    @test_warn "`foo` is not a plotly.js trace type" PlotlyLight.check_attributes(:foo)
    @test_nowarn PlotlyLight.check_attributes(:scatter; x=1:10)
end

@testset "settings defaults are merged recursively" begin
    with_settings(layout=Config(xaxis=Config(showgrid=false)), config=Config(toImageButtonOptions=Config(format="svg"))) do
        p = plot.scatter(y=1:3)
        p.layout.xaxis.title.text = "X"
        p.config.toImageButtonOptions.scale = 2
        out = html(p)
        @test occursin("\"xaxis\":{\"showgrid\":false,\"title\":{\"text\":\"X\"}}", out)
        @test occursin("\"toImageButtonOptions\":{\"format\":\"svg\",\"scale\":2}", out)
        @test settings.layout == Config(xaxis=Config(showgrid=false))  # settings are untouched
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
    @test PlotlyLight.save(p, path1) == path1
    PlotlyLight.save(path2, p)
    @test isfile(path1)
    @test isfile(path2)
    # Images (made in headless Chrome: see browser.jl)
    @test_throws "only apply to images" PlotlyLight.save(p, path1; width=100)
    @test_throws "`gif` isn't an image format" PlotlyLight.image(p, "gif")
    @test_throws "No Chrome, Chromium, or Edge found" PlotlyLight.image(p, "svg"; chrome=nothing)
    withenv("CHROME" => "/path/to/chrome") do
        @test PlotlyLight.find_chrome() == "/path/to/chrome"
    end
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
    @test occursin("Loading PlotlyLight.jl plot...", s)
    @test occursin("PlotlyLight couldn't draw this plot: ", s)
    @test occursin("\"$(PlotlyLight.PLOTLY_URL)\"", s)
    # Full pages (save, REPL) work the same way
    @test !occursin("<script src", html(PlotlyLight.html_page(p)))
    @test occursin("[\"$(PlotlyLight.PLOTLY_URL)\"]", html(PlotlyLight.html_page(p)))

    s = sprint((io, x) -> show(io, MIME("juliavscode/html"), x), Plot())
end

@testset "preset" begin
    foreach(name -> @test(isnothing(getproperty(preset.template, name)())), propertynames(preset.template))
    @test occursin("\"template\":{", html(plot.scatter(y=1:3)))  # templates are inserted as JSON
    preset.template.none!()
    @test !occursin("\"template\"", html(plot.scatter(y=1:3)))

    foreach(name -> @test(isnothing(getproperty(preset.source, name)())), propertynames(preset.source))
    preset.source.none!()
    @test isempty(settings.js_deps)
    preset.source.local!()
    @test settings.js_deps[:plotly] == PlotlyLight.artifact("plotly.min.js")
    preset.source.none!()
    preset.display.mathjax!()
    preset.source.cdn!()
    @test collect(settings.js_deps) == [:plotly => PlotlyLight.PLOTLY_URL, :mathjax => PlotlyLight.MATHJAX_URL]  # plotly.js first
    delete!(settings.js_deps, :mathjax)

    # compression: on!/off! set `settings.compression`
    @test isnothing(preset.compression.on!())
    @test settings.compression == (level=6, rtol=0.0, atol=0.0, n=1000)
    @test occursin("DecompressionStream", html(plot.scatter(y=rand(1000))))
    @test !occursin("DecompressionStream", html(plot.scatter(y=rand(999))))
    preset.compression.on!(level=1, rtol=1e-5, n=10)
    @test settings.compression == (level=1, rtol=1e-5, atol=0.0, n=10)
    @test occursin("new Float32Array(", html(plot.scatter(y=rand(10))))
    @test_throws "`level` must be 0 to 9.  Found 10." preset.compression.on!(level=10)
    @test settings.compression.level == 1  # unchanged by the error
    @test isnothing(preset.compression.off!())
    @test settings.compression == PlotlyLight.Settings().compression
    @test !occursin("DecompressionStream", html(plot.scatter(y=rand(1000))))

    # display: fullscreen! styles the plot's div, and default! restores it
    preset.display.fullscreen!()
    @test occursin("style=\"height:100vh; width:100vw\"", html(plot.scatter(y=1:3)))
    @test isnothing(preset.display.default!())
    @test repr("text/html", settings.div) == repr("text/html", PlotlyLight.Settings().div)
    s = html(plot.scatter(y=1:3))
    @test !occursin("100vh", s) && occursin("class=\"plotlylight-plot-div\"", s)

    # Discoverable with tab completion
    @test propertynames(preset) == (:compression, :template, :source, :display)
    @test propertynames(preset.compression) == (:off!, :on!)
    @test :plotly_dark! in propertynames(preset.template)
end

#-----------------------------------------------------------------------------# browser
include("browser.jl")

#-----------------------------------------------------------------------------# Aqua
Aqua.test_all(PlotlyLight,
    deps_compat=(; ignore =[:REPL, :Random], check_extras = (;ignore=[:Test])),
    persistent_tasks = false
)
