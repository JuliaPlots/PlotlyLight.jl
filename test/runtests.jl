using PlotlyLight, Cobweb, Test, Aqua, Dates, JSON3
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
    preset.display.compress!(true)
    @test json(Int[1, 2]) == "numArrFromBase64(Uint8Array,'eJxjZAIAAAYABA==',2)"
    @test json(Int[1 2; 3 4]) == "numArrFromBase64(Uint8Array,'eJxjZGJmAQAAGAAL',2,2)"
    @test json(Float64[1, 2]) == "numArrFromBase64(Float32Array,'eJxjYGiwZ2BgcAAABIMBAA==',2)"
    @test json(Float64[1 2; 3 4]) == "numArrFromBase64(Float32Array,'eJxjYGiwZ2BgcAAiIG5wAAAQgwJA',2,2)"
    @test json(["a", "b"]) == "strVecFromBase64('eJxLTAIAASYAxA==',numArrFromBase64(Uint8Array,'eJxjZAQAAAUAAw==',2))"
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
    @test contains(JSON3.write(plot(y=1:10)), "scatter")
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
    @test propertynames(JSON3.read(JSON3.write(Plot()))) == [:data, :layout, :config]
end

@testset "show/display" begin
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
