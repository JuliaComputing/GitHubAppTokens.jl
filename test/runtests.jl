using Test
using TimeZones

using GitHubAppTokens
using Dates

@testset "Refresh margin" begin
    t = DateTime(2026, 1, 1, 12, 0, 0)
    @test GitHubAppTokens._expires_soon(t - Second(1), t)    # already expired
    @test GitHubAppTokens._expires_soon(t + Second(30), t)   # less than a minute left
    @test GitHubAppTokens._expires_soon(t + Second(59), t)
    @test !GitHubAppTokens._expires_soon(t + Second(60), t)
    @test !GitHubAppTokens._expires_soon(t + Minute(30), t)
end

@testset "Connect errors are retryable" begin
    HTTP = GitHubAppTokens.HTTP
    err = try
        HTTP.get("http://127.0.0.1:1/"; retry=false)
    catch ex
        ex
    end
    @test GitHubAppTokens._is_connect_error(err)
    @test !GitHubAppTokens._is_connect_error(ErrorException("Status Code: 404"))
    if !isdefined(HTTP, :ConnectError)
        # HTTP 0.9 throws these unwrapped
        @test GitHubAppTokens._is_connect_error(GitHubAppTokens.Sockets.DNSError("x", 0))
        @test GitHubAppTokens._is_connect_error(HTTP.ConnectionPool.ConnectTimeout("x", "443"))
    end
end

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

        # A token that is still valid but expires within the refresh margin is replaced too
        expiring = GitHubAppTokens._GHToken(newtoken, now(Dates.UTC) + Second(30))
        ctx.installation_id_token_cache[inst_id] = expiring
        newtoken2 = get_token_for_repo(ctx, "registratortestorg", "PrivateAnalysis.jl")
        @test newtoken2 !== newtoken
        @test !GitHubAppTokens._expires_soon(ctx.installation_id_token_cache[inst_id].expires_at)

        # Same for a JWT within the refresh margin of its expiry
        # (compare iat, not the JWT string: a JWT minted within the same second is identical)
        ctx.iat = now(Dates.UTC) - Minute(ctx.exp_mins) + Second(30)
        GitHubAppTokens._refresh_jwt_if_needed!(ctx)
        @test !GitHubAppTokens._expires_soon(ctx.iat + Minute(ctx.exp_mins))

        # A nonexistent installation (404) returns nothing and drops any stale cached token
        bogus_inst_id = 1
        ctx.installation_id_token_cache[bogus_inst_id] =
            GitHubAppTokens._GHToken("stale", now(Dates.UTC) - Hour(1))
        @test GitHubAppTokens._get_token_for_installation(ctx, bogus_inst_id) === nothing
        @test !haskey(ctx.installation_id_token_cache, bogus_inst_id)

        # A repo whose cached installation is gone falls back to any token, and the
        # stale installation ID is forgotten so the next call looks it up again
        ctx.repo_installation_id_cache["registratortestorg/PrivateAnalysis.jl"] = bogus_inst_id
        @test get_token_for_repo(ctx, "registratortestorg", "PrivateAnalysis.jl") !== nothing
        @test !haskey(ctx.repo_installation_id_cache, "registratortestorg/PrivateAnalysis.jl")
        @test get_token_for_repo(ctx, "registratortestorg", "PrivateAnalysis.jl") !== nothing
        @test ctx.repo_installation_id_cache["registratortestorg/PrivateAnalysis.jl"] == inst_id

        # A deleted installation usually covers many repos. With no unexpired tokens
        # cached, a 404 forgets every repo mapped to it, and the fallback moves on to
        # the next cached installation id (#9)
        empty!(ctx.installation_id_token_cache)
        ctx.repo_installation_id_cache["registratortestorg/DeadA.jl"] = bogus_inst_id
        ctx.repo_installation_id_cache["registratortestorg/DeadB.jl"] = bogus_inst_id
        GitHubAppTokens._set_token_not_applicable!(ctx, "registratortestorg", "NotInstalled.jl")
        @test get_token_for_repo(ctx, "registratortestorg", "NotInstalled.jl") !== nothing
        @test !(bogus_inst_id in values(ctx.repo_installation_id_cache))
        @test ctx.repo_installation_id_cache["registratortestorg/PrivateAnalysis.jl"] == inst_id

        # When every cached installation id is dead, fall through to the installations
        # listed by GitHub
        empty!(ctx.installation_id_token_cache)
        empty!(ctx.repo_installation_id_cache)
        ctx.repo_installation_id_cache["registratortestorg/DeadA.jl"] = bogus_inst_id
        ctx.repo_installation_id_cache["registratortestorg/DeadB.jl"] = bogus_inst_id
        @test get_token_for_repo(ctx, "registratortestorg", "NotInstalled.jl") !== nothing
        @test !(bogus_inst_id in values(ctx.repo_installation_id_cache))

        # Deleting a missing key is a no-op (LRU's delete! throws KeyError)
        @test GitHubAppTokens._delete_if_present!(ctx.repo_installation_id_cache, "no/such") ===
            nothing

        # _parse_github_url
        @test GitHubAppTokens._parse_github_url("https://github.com/JuliaLang/julia") ==
            ("JuliaLang", "julia")
        @test GitHubAppTokens._parse_github_url(
            "https://api.github.com/repos/JuliaLang/julia/artifacts/1234"
        ) ==
            ("JuliaLang", "julia")
    end
end
