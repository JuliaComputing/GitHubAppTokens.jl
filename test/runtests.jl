using Test
using TimeZones

using GitHubAppTokens
using Dates

mktemp() do path, _
    open(path, "w") do f
        write(f, ENV["APP_PRIVKEY"])
    end
    ctx = GHAppCtx(parse(Int, ENV["APP_ID"]), path, "https://github.com")
    @testset "Test getting tokens" begin
        # Should throw error for invalid repo namespace or name
        @test_throws ArgumentError get_token_for_repo(
            ctx, "registratortestorg\"; rm -rf /; #\"", "TestReg"
        )
        @test_throws ArgumentError get_token_for_repo(
            ctx, "registratortestorg", "TestReg\"; rm -rf /; #\""
        )
        # Get a token for a repo, check that JWT and iat have not changed, i.e, JWT is not refreshed
        curr_jwt = ctx.jwtauth.JWT
        iat = ctx.iat
        token = get_token_for_repo(ctx, "registratortestorg", "PrivateAnalysis.jl")
        @test token !== nothing
        # Works when .git is in the repo_name
        token = get_token_for_repo(ctx, "registratortestorg", "PrivateAnalysis.jl.git")
        @test token !== nothing
        # Get token again, should be same as old token
        token2 = get_token_for_repo(ctx, "registratortestorg", "PrivateAnalysis.jl")
        @test token2 === token
        # JWT should not be refreshed
        @test curr_jwt == ctx.jwtauth.JWT
        @test iat == ctx.iat
        # Check token in cache
        inst_id = get(
            ctx.repo_installation_id_cache, "registratortestorg/PrivateAnalysis.jl", nothing
        )
        @test inst_id !== nothing
        token_in_cache = get(ctx.installation_id_token_cache, inst_id, nothing)
        @test token_in_cache.token === token
        @test token_in_cache.expires_at > now(Dates.UTC)

        # Get another token, fake a refresh by manually expiring the JWT iat
        ctx.iat = now(Dates.UTC) - Hour(1)  # Force a refresh
        token3 = get_token_for_repo(ctx, "nkottary", "CookieTest.jl")
        @test token3 !== nothing
        @test token3 !== token
        @test curr_jwt != ctx.jwtauth.JWT   # Check for refresh
        @test iat != ctx.iat

        # Expire the access token and see if you get a new one
        exp_token = GitHubAppTokens._GHToken(token, now(Dates.UTC) - Hour(1))
        ctx.installation_id_token_cache[inst_id] = exp_token
        newtoken = get_token_for_repo(ctx, "registratortestorg", "PrivateAnalysis.jl")
        @test token !== newtoken

        # _parse_github_url
        @test GitHubAppTokens._parse_github_url("https://github.com/JuliaLang/julia") ==
            ("JuliaLang", "julia")
        @test GitHubAppTokens._parse_github_url(
            "https://api.github.com/repos/JuliaLang/julia/artifacts/1234"
        ) ==
            ("JuliaLang", "julia")
    end
end
