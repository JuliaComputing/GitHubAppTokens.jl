using JET: JET
using Test

struct CustomReportFilter
    analyzed_package_name::AbstractString
end

function JET.configured_reports(crf::CustomReportFilter, reports::Vector{JET.InferenceErrorReport})
    filter(reports) do report
        excluded = (
            "Base",
            "InteractiveUtils",
            "NetworkOptions",
            "Dates",
            "Sockets",
            "HTTP",
            "ConcurrentUtilities",
            "LRUCache",
            "Random",
            "JSON",
            # JSON.jl 1.x parses through StructUtils; its generic `lift` fallbacks
            # are flagged the same way JSON's own internals would be
            "StructUtils",
            "Serialization",
            "GitHub",
            # HTTP.jl 2.x's transport layer
            "Reseau",
        )

        m = string(last(report.vst).linfo.def.module)

        if m != crf.analyzed_package_name
            # We want to report on the analyzed package even if it's in the common exclude list
            for i in excluded
                occursin(i, m) && return false
            end
        end

        if isa(report, JET.MethodErrorReport) && report.union_split > 1
            return false
        end

        return true
    end
end

function test_jet(name)
    @testset "JET" begin
        JET.test_package(
            name;
            report_config=CustomReportFilter(string(name)),
        )
    end
end
