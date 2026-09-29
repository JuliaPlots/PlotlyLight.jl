module PlotlyLightJSONExt

using PlotlyLight, JSON

# Parsed on first use (~30ms) rather than at load time, so loading JSON costs nothing until the schema is needed
const SCHEMA = Ref{Union{Nothing, JSON.Object{String, Any}}}(nothing)

function schema()
    isnothing(SCHEMA[]) && (SCHEMA[] = JSON.parsefile(PlotlyLight.artifact("plot-schema.json")))
    return SCHEMA[]
end

end
