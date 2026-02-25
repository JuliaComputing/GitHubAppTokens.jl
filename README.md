GitHubAppTokens.jl
------------------

Retrieve access tokens for GitHub repos as a GitHub app.

```
using GitHubAppTokens
ctx = GHAppCtx(12345, "privkey.pem")
token = GitHubAppTokens.get_token_for_repo(ctx, "myorg", "myrepo")
```
