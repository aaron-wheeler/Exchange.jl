using Exchange
using Documenter

DocMeta.setdocmeta!(Exchange, :DocTestSetup, :(using Exchange); recursive=true)

makedocs(;
    modules=[Exchange],
    authors="aaron-wheeler",
    repo="https://github.com/aaron-wheeler/Exchange.jl/blob/{commit}{path}#{line}",
    sitename="Exchange.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://aaron-wheeler.github.io/Exchange.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/aaron-wheeler/Exchange.jl",
    devbranch="main",
)
