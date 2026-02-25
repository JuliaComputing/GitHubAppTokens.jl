GitHubAppTokens.jl
------------------

A [Julia](https://julialang.org) client package to [authenticate as GitHub apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/about-authentication-with-a-github-app).
Caching and refreshing expired tokens are managed automatically.

### Usage

```julia
# Load the package
using GitHubAppTokens

# Create the client context with your GitHub app's ID and private key file
ctx = GHAppCtx(12345, "privkey.pem")

# Generate or retrieve token for a repo
token = GitHubAppTokens.get_token_for_repo(ctx, "myorg", "myrepo")
```
