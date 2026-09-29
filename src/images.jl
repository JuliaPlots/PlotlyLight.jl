#-----------------------------------------------------------------------------# headless Chrome
# A Chrome-based browser (Chrome, Chromium, or Edge): ENV["CHROME"], else the first one found, else `nothing`
function find_chrome()
    haskey(ENV, "CHROME") && return ENV["CHROME"]
    candidates = [
        "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        raw"C:\Program Files\Google\Chrome\Application\chrome.exe",
        raw"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        joinpath(get(ENV, "LOCALAPPDATA", ""), "Google", "Chrome", "Application", "chrome.exe"),
        raw"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        raw"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    ]
    for c in candidates
        path = isabspath(c) ? (isfile(c) ? c : nothing) : Sys.which(c)
        isnothing(path) || return path
    end
    return nothing
end

file_url(path) = "file://" * replace(Sys.iswindows() ? "/" * replace(abspath(path), '\\' => '/') : abspath(path), " " => "%20")

no_chrome_error() = ErrorException("""
    No Chrome, Chromium, or Edge found, which PlotlyLight needs to make images.  Install one, or set
    `ENV["CHROME"]` to the path of its executable.""")

# The DOM of the HTML `file` after headless Chrome has run its scripts
function dump_dom(file; chrome=find_chrome(), timeout=60)
    isnothing(chrome) && throw(no_chrome_error())
    mktempdir() do dir
        cmd = `$chrome --headless=new --no-sandbox --disable-gpu --no-first-run --user-data-dir=$(joinpath(dir, "profile"))
            --allow-file-access-from-files --virtual-time-budget=15000 --dump-dom $(file_url(file))`
        p = open(pipeline(cmd; stderr=devnull))
        timer = Timer(_ -> kill(p), timeout)
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
            wait(p)
        end
        String(take!(dom))
    end
end

#-----------------------------------------------------------------------------# images
const IMAGE_FORMATS = OrderedDict(".svg" => "svg", ".png" => "png", ".jpg" => "jpeg", ".jpeg" => "jpeg", ".webp" => "webp")

# A page that draws `p` with plotly.js's `toImage` and writes the image (or the error), base64-encoded, in a <pre>
function image_page(p::Plot, opts::Config)
    q = apply(p, settings)
    # The local plotly.js (the same version as the CDN's), and any other scripts (e.g. MathJax)
    deps = OrderedDict(:plotly => file_url(artifact("plotly.min.js")), filter(kv -> kv[1] ≠ :plotly, settings.js_deps)...)
    io = IOBuffer()
    print(io, "<!doctype html><html><head><meta charset=\"utf-8\">")
    foreach(d -> show(io, MIME("text/html"), d isa InlineScript ? d : h.script(; src=d)), values(deps))
    print(io, """</head><body><pre id="out"></pre><script>(async () => {
        const out = document.getElementById("out");
        const b64 = s => btoa(Array.from(new TextEncoder().encode(s), b => String.fromCharCode(b)).join(""));
        try {
            const opts = $(json(opts));
            const img = await Plotly.toImage(""")
    json(io, (; data=q.data, layout=q.layout, config=q.config))
    print(io, """, opts);
            out.id = "image";
            out.textContent = opts.format == "svg" ? b64(img) : img;
        } catch (e) {
            out.id = "error";
            out.textContent = b64(String(e?.message ?? e));
        }
    })()</script></body></html>""")
    String(take!(io))
end

# `p` as an image (bytes), drawn by plotly.js in headless Chrome.  `format` is "svg", "png", "jpeg", or "webp".  Sizes
# default to the plot's `layout.width`/`layout.height` (otherwise 700 × 450), and `scale` multiplies raster pixels.
function image(p::Plot, format="png"; width=nothing, height=nothing, scale=nothing, chrome=find_chrome())
    format ∈ values(IMAGE_FORMATS) || throw(ArgumentError("`$format` isn't an image format.  Use one of: \"svg\", \"png\", \"jpeg\", \"webp\"."))
    isnothing(chrome) && throw(no_chrome_error())
    opts = Config(; format, imageDataOnly=true)
    foreach(((k, v),) -> isnothing(v) || (opts[k] = v), pairs((; width, height, scale)))
    dom = mktempdir() do dir
        file = joinpath(dir, "image.html")
        write(file, image_page(p, opts))
        dump_dom(file; chrome)
    end
    m = match(r"<pre id=\"(image|error)\">([A-Za-z0-9+/=]*)</pre>", dom)
    isnothing(m) && error("Chrome (`$chrome`) didn't make the image.")
    bytes = base64decode(m[2])
    m[1] == "error" && error("plotly.js couldn't make the image: ", String(bytes))
    return bytes
end

#-----------------------------------------------------------------------------# save
# An image for the extensions in IMAGE_FORMATS (`kw` are `image`'s keywords), otherwise an HTML page
function save(p::Plot, file::AbstractString; kw...)
    format = get(IMAGE_FORMATS, lowercase(splitext(file)[2]), nothing)
    if isnothing(format)
        isempty(kw) || throw(ArgumentError("Keyword arguments only apply to images ($(join(keys(IMAGE_FORMATS), ", ")) files)."))
        open(io -> show(io, MIME("text/html"), html_page(p)), file, "w")
    else
        write(file, image(p, format; kw...))
    end
    return file
end
save(file::AbstractString, p::Plot; kw...) = save(p, file; kw...)
