using Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()

using ArtifactUtils, JSON
using Pkg.Artifacts: archive_artifact

version = get(ENV, "PLOTLY_VERSION") do
    JSON.parsefile(download("https://api.github.com/repos/plotly/plotly.js/releases/latest"))["name"]
end


#-----------------------------------------------------------------------------# get urls
plotly_url = "https://github.com/plotly/plotly.js/raw/$version/dist/plotly.min.js"

schema_url = "https://github.com/plotly/plotly.js/raw/$version/dist/plot-schema.json"

template_urls = let
    jq = """.[] | select(.name | endswith(".json")) | .download_url"""
    urls = readlines(`gh api repos/plotly/plotly.py/contents/plotly/package_data/templates --jq $jq`)
    Dict(splitext(basename(url))[1] => url for url in urls)
end

#-----------------------------------------------------------------------------# make tempdir
dir = mktempdir()
mkdir(joinpath(dir, "templates"))

#-----------------------------------------------------------------------------# download
open(io -> println(io, version), joinpath(dir, "version.txt"), "w")
download(plotly_url, joinpath(dir, "plotly.min.js"))
download(schema_url, joinpath(dir, "plot-schema.json"))
for (k,v) in template_urls
    download(v, joinpath(dir, "templates", "$k.json"))
end

#-----------------------------------------------------------------------------# make artifact
artifact_id = artifact_from_directory(dir)
tarball = joinpath(mktempdir(), "plotly_artifacts-$artifact_id.tar.gz")
archive_artifact(artifact_id, tarball)

#-----------------------------------------------------------------------------# upload to GitHub release
# Tarballs accumulate as assets of one release.  Never delete them: old PlotlyLight versions download from here.
repo = get(ENV, "GITHUB_REPOSITORY") do
    readchomp(Cmd(`gh repo view --json nameWithOwner --jq .nameWithOwner`; dir=@__DIR__))
end
tag = "artifacts"

if !success(pipeline(`gh release view $tag --repo $repo`; stdout=devnull, stderr=devnull))
    notes = "Plotly.js artifact tarballs referenced by Artifacts.toml.  Do not delete."
    run(`gh release create $tag --repo $repo --title Artifacts --notes $notes --latest=false`)
end
assets = readlines(`gh release view $tag --repo $repo --json assets --jq '.assets[].name'`)
basename(tarball) in assets || run(`gh release upload $tag $tarball --repo $repo`)

url = "https://github.com/$repo/releases/download/$tag/$(basename(tarball))"
add_artifact!(joinpath(@__DIR__, "..", "Artifacts.toml"), "plotly_artifacts", url; force=true)
