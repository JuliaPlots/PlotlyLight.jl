# Renders plots in headless Chrome inside pages that reproduce how each environment runs a plot's HTML, then checks
# what drew.  plotly.js comes from the local artifact (no network).  Skipped without Chrome/Chromium; set
# ENV["CHROME"] to choose the executable.

using PlotlyLight, Test, JSON, Base64
using PlotlyLight: settings, json
using Cobweb: h

function find_chrome()
    haskey(ENV, "CHROME") && return ENV["CHROME"]
    for c in ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
              "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              raw"C:\Program Files\Google\Chrome\Application\chrome.exe",
              raw"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"]
        path = isabspath(c) ? (isfile(c) ? c : nothing) : Sys.which(c)
        isnothing(path) || return path
    end
    return nothing
end

file_url(path) = "file://" * replace(Sys.iswindows() ? "/" * replace(abspath(path), '\\' => '/') : abspath(path), " " => "%20")

#-----------------------------------------------------------------------------# rendering
# Collects what happened on the page after the plots have had time to draw (`_fullData`: data after plotly.js decoded
# any typed arrays).  Base64 so the JSON survives Chrome's `--dump-dom` HTML escaping.
const REPORT_JS = """<script>setTimeout(() => {
    const all = sel => [...document.querySelectorAll(sel)];
    const arr = a => a == null ? null : Array.from(a, v => ArrayBuffer.isView(v) || Array.isArray(v) ? arr(v) : v);
    const report = {
        plots: all(".js-plotly-plot").map(p => p._fullData.map(t => ({x: arr(t.x), y: arr(t.y), text: arr(t.text), z: arr(t.z)}))),
        fallbacks: all(".plotlylight-plot-div").filter(d => d.textContent.includes("Loading PlotlyLight.jl plot")).length,
        errors: all(".plotlylight-plot-div pre").map(e => e.textContent),
        plotly_scripts: all("script[src*='plotly']").length,
    };
    const pre = document.createElement("pre");
    pre.id = "report";
    pre.textContent = btoa(unescape(encodeURIComponent(JSON.stringify(report))));
    document.body.appendChild(pre);
}, 3000)</script>"""

# The report from rendering `body` (HTML) in headless Chrome
function render(chrome, body; head="")
    dir = mktempdir()
    file = joinpath(dir, "page.html")
    write(file, "<!doctype html><html><head><meta charset=\"utf-8\">$head</head><body>$body$REPORT_JS</body></html>")
    cmd = `$chrome --headless=new --no-sandbox --disable-gpu --no-first-run --user-data-dir=$(joinpath(dir, "profile"))
        --allow-file-access-from-files --virtual-time-budget=15000 --dump-dom $(file_url(file))`
    p = open(pipeline(cmd; stderr=devnull))
    timer = Timer(_ -> kill(p), 120)
    dom = IOBuffer()
    try
        while !eof(p)  # Chrome sometimes lingers after dumping the DOM, so stop reading at `</html>`
            line = readline(p; keep=true)
            write(dom, line)
            occursin("</html>", line) && break
        end
    finally
        close(timer)
        kill(p)
    end
    m = match(r"<pre id=\"report\">([A-Za-z0-9+/=]*)</pre>", String(take!(dom)))
    isnothing(m) && error("No report from Chrome (the page's scripts may not have run)")
    return JSON.parse(String(base64decode(m[1])))
end

#-----------------------------------------------------------------------------# hosts
# How each environment runs a plot's HTML.  `html` is what PlotlyLight shows as text/html.
payload(html) = json(html)  # a JS string literal (escapes `<`, so it can't end the host page's <script>)

# Static page: Documenter, Quarto, a saved file, and VS Code's plot pane (julia-vscode wraps the HTML in a full page;
# see `wrapHtml` in its src/interactive/plots.ts)
static(html) = html

# Documenter and the classic Jupyter Notebook load require.js.  UMD bundles then register as AMD modules instead of
# setting globals, which broke an earlier decoder library.
amd(html) = "<script>window.define = function() {}; window.define.amd = {};</script>" * html

# Pluto (frontend/components/CellOutput.js `execute_scripttags`): inserts the HTML, then runs each <script> in order,
# awaiting `src` ones and running inline ones inside their own async function.
pluto(html) = """<div id="out"></div><script>(async () => {
    const out = document.getElementById("out");
    out.innerHTML = $(payload(html));
    for (const node of out.querySelectorAll("script")) {
        if (node.src) {
            const s = document.createElement("script");
            s.src = node.src;
            document.head.appendChild(s);
            await new Promise(r => s.onload = s.onerror = r);
        } else {
            await Function(`"use strict"; return (async () => {\${node.textContent}})()`)();
        }
    }
})()</script>"""

# Renderers that insert the HTML and then re-create each <script> so it runs (JupyterLab-style output areas, many web
# frameworks).  Re-created `src` scripts load asynchronously, so nothing may assume they've run.
recreate(html) = """<div id="out"></div><script>
    const out = document.getElementById("out");
    out.innerHTML = $(payload(html));
    for (const old of out.querySelectorAll("script")) {
        const s = document.createElement("script");
        old.src ? (s.src = old.src) : (s.textContent = old.textContent);
        old.replaceWith(s);
    }
</script>"""

# Browsers without `Uint8Array.fromBase64` (before Chrome 140, Firefox 133, Safari 18.2)
no_from_base64(html) = "<script>delete Uint8Array.fromBase64;</script>" * html

# Hosts that insert the HTML but never run its scripts (e.g. an untrusted notebook)
no_js(html) = """<div id="out"></div><script>document.getElementById("out").innerHTML = $(payload(html));</script>"""

#-----------------------------------------------------------------------------# tests
chrome = find_chrome()
if isnothing(chrome)
    @info "Skipping browser tests: no Chrome/Chromium found (set ENV[\"CHROME\"])"
else
    @testset "browser: $chrome" begin
        local_plotly = file_url(PlotlyLight.artifact("plotly.min.js"))
        tricky = ["say \"hi\"", "back\\slash", "new\nline", "</script><b>x</b>", "</script x", "a<br>b", "😀", "tab\there"]
        y = 45 .+ (1:200) ./ 1e5
        text = [tricky; string.("p", 8:200)]
        z = Float64.(reshape(repeat(1:6, 50), 3, 100))  # compresses, and rows differ from columns
        img = reshape(UInt8.(1:24), 2, 4, 3)  # rows × columns × rgb
        p = plot.scatter(x = 1:200, y = y, text = text)(plot.heatmap(z = z))(plot.image(z = img))
        p_typed = plot.scatter(x = TypedArray(1:200), y = TypedArray(y), text = text)(plot.heatmap(z = TypedArray(z)))(
            plot.image(z = TypedArray(img)))
        p_compressed = plot.scatter(x = Compressed(1:200), y = Compressed(y), text = Compressed(text))(
            plot.heatmap(z = Compressed(z)))(plot.image(z = Compressed(img)))

        # `f()` with default settings, local plotly.js, and `kw` overrides
        function with_defaults(f; kw...)
            old = PlotlyLight.settings
            PlotlyLight.settings = PlotlyLight.Settings(; js_deps=PlotlyLight.OrderedDict(:plotly => local_plotly), kw...)
            try
                f()
            finally
                PlotlyLight.settings = old
            end
        end
        html(x; kw...) = with_defaults(() -> repr("text/html", x); kw...)

        # The plot drew, and its data made it through intact
        function drew(report; n=1)
            @test length(report["plots"]) == n
            @test report["fallbacks"] == 0
            @test isempty(report["errors"])
            scatter, heatmap, image = first(report["plots"])
            @test scatter["x"] == 1:200
            @test scatter["y"] == y
            @test scatter["text"] == text
            @test heatmap["z"] == [z[i, :] for i in 1:3]  # rows
            @test image["z"] == [[img[i, j, :] for j in 1:4] for i in 1:2]  # z[i][j] is the color of pixel (i, j)
        end

        for (name, host) in ["static page" => static, "AMD (require.js) page" => amd, "Pluto" => pluto,
                             "re-created scripts" => recreate, "no Uint8Array.fromBase64" => no_from_base64]
            @testset "$name" begin
                drew(render(chrome, host(html(p))))
                drew(render(chrome, host(html(p_typed))))
                @test occursin(".arrayBuffer()", html(p_compressed)) && occursin(".json()", html(p_compressed))
                drew(render(chrome, host(html(p_compressed))))
            end
        end

        @testset "VS Code (juliavscode/html)" begin
            vscode = with_defaults(() -> sprint(show, MIME("juliavscode/html"), p))
            drew(render(chrome, static(vscode)))
        end

        @testset "several plots load plotly.js once" begin
            report = render(chrome, join(map(_ -> html(p), 1:3)))
            drew(report; n=3)
            @test report["plotly_scripts"] == 1
        end

        @testset "Compressed Float16 (Float16Array)" begin
            report = render(chrome, html(plot.scatter(y = Compressed(Float16[0.5, 1.5, 2.5]))))
            @test isempty(report["errors"])
            @test only(only(report["plots"]))["y"] == [0.5, 1.5, 2.5]
        end

        @testset "saved file (html_page)" begin
            page = with_defaults(() -> repr("text/html", PlotlyLight.html_page(p)))
            body = match(r"<body>(.*)</body>"s, page)[1]
            drew(render(chrome, body))
        end

        @testset "failures explain themselves" begin
            # Scripts never run: the fallback message stays
            report = render(chrome, no_js(html(p)))
            @test isempty(report["plots"])
            @test report["fallbacks"] == 1

            # plotly.js fails to load: the reason replaces the fallback
            missing_plotly = file_url(joinpath(mktempdir(), "no-plotly.js"))
            report = render(chrome, html(p; js_deps=PlotlyLight.OrderedDict(:plotly => missing_plotly)))
            @test isempty(report["plots"])
            @test report["fallbacks"] == 0
            @test only(report["errors"]) == "PlotlyLight couldn't draw this plot: Plotly isn't loaded on the page."

            # Another script (e.g. MathJax) fails to load: the plot still draws
            missing_extra = file_url(joinpath(mktempdir(), "no-mathjax.js"))
            drew(render(chrome, html(p; js_deps=PlotlyLight.OrderedDict(:plotly => local_plotly, :mathjax => missing_extra))))
        end
    end
end
