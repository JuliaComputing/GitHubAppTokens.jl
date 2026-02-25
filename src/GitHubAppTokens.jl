module GitHubAppTokens

using GitHub
using LRUCache
using Retry
using HTTP
using Dates
using JSON

export GHAppCtx, get_token_for_repo

struct _GHToken
    token::String
    expires_at::DateTime
end

mutable struct GHAppCtx
    appid::Int
    privkeypath::String
    jwtauth::GitHub.JWTAuth
    iat::Dates.DateTime
    exp_mins::Int
    repo_installation_id_cache::LRU{String, Int}
    installation_id_token_cache::LRU{Int, _GHToken}
    token_applicable::LRU{String, Bool}
    api::GitHub.GitHubWebAPI
end

function GHAppCtx(appid::Int, privkeypath::AbstractString, urlprefix::AbstractString="*")
    if !isfile(privkeypath)
        @error("Private key file does not exist", privkeypath)
        throw(ArgumentError("Private key file does not exist"))
    end

    # As per guidelines in GitHub's documentation, the iat for the JWT is recommended to be set to 60 seconds in the past to protect against clock drift: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app#about-json-web-tokens-jwts
    iat = now(Dates.UTC) - Dates.Second(60)
    exp_mins = 5
    jwtauth = GitHub.JWTAuth(appid, privkeypath; iat=iat, exp_mins=exp_mins)
    id_cache = LRU{String, Int}(; maxsize=10000)
    token_cache = LRU{Int, _GHToken}(; maxsize=5)
    applicable_cache = LRU{String, Bool}(; maxsize=10000)
    u = first(split(urlprefix, ","))
    api_url = if u == "*" || u == "github.com" || u == "https://github.com"
        "https://api.github.com"
    else
        u
    end

    return GHAppCtx(
        appid,
        privkeypath,
        jwtauth,
        iat,
        exp_mins,
        id_cache,
        token_cache,
        applicable_cache,
        GitHub.GitHubWebAPI(HTTP.URIs.URI(api_url)),
    )
end

function _refresh_jwt_if_needed!(ctx::GHAppCtx)::Nothing
    # Refresh if less than a minute is left for expiry of JWT
    iat = now(Dates.UTC) - Dates.Second(60)
    if (ctx.iat + Dates.Minute(ctx.exp_mins)) < iat
        ctx.jwtauth = GitHub.JWTAuth(ctx.appid, ctx.privkeypath; iat=iat, exp_mins=5)
        ctx.iat = iat
    end
    nothing
end

function _validate_repo_part(part::AbstractString, part_name::AbstractString)::Nothing
    if match(r"^[[:alnum:]_\.\-]+$", part) === nothing
        throw(ArgumentError("`$part_name` is invalid"))
    end
    nothing
end

function _get_repo_installation_id(
    ctx::GHAppCtx, repo_namespace::AbstractString, repo_name::AbstractString
)::Union{Int, Nothing}
    repo_full_name = repo_namespace * "/" * repo_name
    inst_id = get(ctx.repo_installation_id_cache, repo_full_name, nothing)
    if inst_id === nothing
        _refresh_jwt_if_needed!(ctx)
        # Do not change the following to `inst_id = @repeat 5 try...` etc
        # `@repeat n try...` does not return inner values in the same way that
        # a `try` does.
        inst_id = nothing
        @repeat 5 try
            inst_id = GitHub.installation(ctx.api, GitHub.Repo(repo_full_name), ctx.jwtauth).id
        catch ex
            @delay_retry if isa(ex, HTTP.Exceptions.ConnectError)
                @debug("Error connecting to GitHub: ", ex)
            end
            @ignore if isa(ex, ErrorException) && occursin("Status Code: 404", ex.msg)
            end
            if !isa(ex, HTTP.Exceptions.ConnectError) &&
                !(isa(ex, ErrorException) && occursin("Status Code: 404", ex.msg))
                rethrow(ex)
            end
        end
        if inst_id !== nothing
            ctx.repo_installation_id_cache[repo_full_name] = inst_id
        end
    end

    return inst_id
end

function _get_token_for_installation(ctx::GHAppCtx, inst_id::Int)::Union{String, Nothing}
    token = get(ctx.installation_id_token_cache, inst_id, nothing)
    # Refresh the access token if less than a minute is left for expiry
    if token === nothing || token.expires_at < (now(Dates.UTC) - Second(60))
        _refresh_jwt_if_needed!(ctx)
        # Do not change the following to `resp = @repeat 5 try...` etc
        # `@repeat n try...` does not return inner values in the same way that
        # a `try` does.
        resp = nothing
        @repeat 5 try
            resp = HTTP.post(
                string(ctx.api.endpoint) * "/app/installations/$(inst_id)/access_tokens";
                headers=[
                    "Accept" => "application/vnd.github+json",
                    "Authorization" => "Bearer $(ctx.jwtauth.JWT)",
                    "X-GitHub-Api-Version" => "2022-11-28",
                ],
            )
        catch ex
            @delay_retry if isa(ex, HTTP.Exceptions.ConnectError)
                @debug("Error connecting to GitHub: ", ex)
            end
            @ignore if isa(ex, ErrorException) && occursin("Status Code: 404", ex.msg)
            end
            if !isa(ex, HTTP.Exceptions.ConnectError) &&
                !(isa(ex, ErrorException) && occursin("Status Code: 404", ex.msg))
                rethrow(ex)
            end
        end
        if resp !== nothing
            j = JSON.parse(String(resp.body))
            token =
                ctx.installation_id_token_cache[inst_id] = _GHToken(
                    j["token"], DateTime(j["expires_at"], "yyyy-mm-ddTHH:MM:SSz")
                )
            # TODO: Optimize? Since we've missed the cache anyway, let's make another call to GitHub.repos with this token so that we can mark the cache for more repos?
        end
    end

    return token.token
end

"""
Get a token by picking an arbitrary installation ID from the cache. Or if the cache is
totally empty, get a list of installations and pick the first one, get the token for that.
"""
function _get_any_token(ctx::GHAppCtx)::Union{String, Nothing}
    # Get all tokens from the cache that have not expired
    tokens = filter(
        x -> x.expires_at >= (now(Dates.UTC) + Second(60)),
        collect(values(ctx.installation_id_token_cache)),
    )
    if !isempty(tokens)
        return first(tokens).token
    end
    # If there were no un-expired tokens, then get an installation id
    inst_ids = collect(values(ctx.repo_installation_id_cache))
    if !isempty(inst_ids)
        inst_id = first(inst_ids)
        return _get_token_for_installation(ctx, inst_id)
    end
    # If even the installation id cache was empty, get list of installation
    # IDs from GitHub, get a token for the first one, cache that for future
    inst_ids = GitHub.installations(ctx.api, ctx.jwtauth)[1]
    # If the app was not installed anywhere, there isn't much we can do
    if isempty(inst_ids)
        @warn("Could not get any installations for GitHub app")
        return nothing
    end

    return _get_token_for_installation(ctx, first(inst_ids).id)
end

"""
By default, token generation is applicable for all packages
"""
_is_token_applicable(ctx, repo_namespace, repo_name) =
    get(ctx.token_applicable, repo_namespace * "/" * repo_name, true)

function _set_token_not_applicable!(ctx, repo_namespace, repo_name)
    ctx.token_applicable[repo_namespace * "/" * repo_name] = false
    nothing
end

"""
Returns a string token for the given repo. If a token could not be generated,
such as when the github app is not installed on the given repo, we return
an arbitrary token, see _get_any_token. Returns `nothing` when github app is
not installed anywhere.
"""
function get_token_for_repo(
    ctx::GHAppCtx, repo_namespace::AbstractString, repo_name::AbstractString
)::Union{String, Nothing}
    repo_name = _maybe_remove_dot_git(repo_name)
    _validate_repo_part(repo_namespace, "repo_namespace")
    _validate_repo_part(repo_name, "repo_name")

    # If we have previously determined that token generation is not
    # applicable for this package, just return any token
    if !_is_token_applicable(ctx, repo_namespace, repo_name)
        return _get_any_token(ctx)
    end

    inst_id = _get_repo_installation_id(ctx, repo_namespace, repo_name)
    if inst_id === nothing
        # Cache the fact that installation ID is not available for this
        # package so that we don't keep querying for installation ID
        # repeatedly
        _set_token_not_applicable!(ctx, repo_namespace, repo_name)
        return _get_any_token(ctx)
    end
    token = _get_token_for_installation(ctx, inst_id)
    @assert token !== nothing
    return token
end

_maybe_remove_dot_git(repo_name::AbstractString) =
    endswith(repo_name, ".git") ? repo_name[1:(end - length(".git"))] : repo_name

function get_token_for_repo(ctx::GHAppCtx, url::AbstractString)
    # Assume URL is github and try to parse. If it isn't github
    # thats ok. We'll still get a token via _get_any_token
    repo_namespace, repo_name = _parse_github_url(url)
    return get_token_for_repo(ctx, repo_namespace, repo_name)
end

function _parse_github_url(url::AbstractString)
    u = HTTP.URIs.URI(url)
    parts = filter(x -> !isempty(x), split(u.path, "/"))
    repo_namespace, repo_name = if startswith(u.host, "api.")
        @assert length(parts) >= 3
        parts[2:3]
    else
        @assert length(parts) >= 2
        parts[1:2]
    end

    return (repo_namespace, _maybe_remove_dot_git(repo_name))
end

end
