# Publishing to RubyGems

Guardrails publishes to [RubyGems.org](https://rubygems.org/) using **RubyGems Trusted Publishing** — no long-lived API key stored in repo secrets. The `.github/workflows/release.yml` workflow runs on every `v*` tag push: it verifies the gemspec version matches the tag, runs the suite, and pushes the gem via a short-lived OIDC token RubyGems mints in exchange for the GitHub Actions identity.

## One-time setup (before the first release)

The gem doesn't exist on RubyGems.org yet, so the trusted publisher is configured as **pending** — it claims the name on the first successful push.

1. **Sign in to rubygems.org** with the account that should own the gem (`meticulous` org owner). Confirm the account has 2FA enabled.

2. **Open the pending trusted publishers page**: <https://rubygems.org/profile/oidc/pending_trusted_publishers> → **Create**.

3. **Fill the form:**

   | Field | Value |
   |---|---|
   | RubyGem name | `ui_guardrails` |
   | Repository owner | `meticulous` |
   | Repository name | `guardrails` |
   | Workflow filename | `release.yml` |
   | Environment | `release` |

4. **Save.** The pending trusted publisher will sit there until the first tagged push from this repo successfully authenticates against it. After that first push, RubyGems automatically converts it to a regular trusted publisher attached to the now-created gem.

## Cutting a release

After the change set is merged to `main`:

```bash
# Pull main locally
git checkout main
git pull --ff-only

# Confirm version + CHANGELOG are in the right shape
grep VERSION lib/guardrails/version.rb
head -20 CHANGELOG.md

# Tag the merge commit and push the tag (replace X.Y.Z with the
# version you're cutting — the next-release example would be the
# version in lib/guardrails/version.rb on main right now).
git tag -a vX.Y.Z -m "vX.Y.Z — <short summary>"
git push origin vX.Y.Z
```

The `release.yml` workflow takes over from there. Watch the run at <https://github.com/meticulous/guardrails/actions> — it'll:

1. Verify `Guardrails::VERSION` matches the tag (refuses to publish a mismatched gem)
2. Run the test suite
3. Build the gem
4. Push to RubyGems.org via trusted publishing

The whole flow typically runs in under 90 seconds.

## What if the workflow fails?

| Failure | Likely cause |
|---|---|
| `Guardrails::VERSION (X.Y.Z) does not match tag (vA.B.C). Refusing to publish.` | The tag points at a commit whose `lib/guardrails/version.rb` doesn't match. Re-tag against the right commit or bump the version. |
| Spec suite fails | Same fix as a regular CI failure — root cause whatever the spec reported. |
| `rubygems/release-gem` fails with an OIDC error | The pending trusted publisher on rubygems.org wasn't created, the workflow filename doesn't match, or the environment name doesn't match. Double-check the form in step 3 above. |

## Manual fallback (legacy path)

If trusted publishing breaks for any reason, the gem can still be published manually with an API key:

1. Create an [API key on rubygems.org](https://rubygems.org/profile/api_keys) with the `push_rubygem` scope. Lock it to the `ui_guardrails` gem.
2. Configure local credentials:
   ```bash
   mkdir -p ~/.gem
   touch ~/.gem/credentials
   chmod 600 ~/.gem/credentials
   # then edit and add:
   # ---
   # :rubygems_api_key: rubygems_xxxxxxxxxxxxxxxxxxxxxxxx
   ```
3. Build and push:
   ```bash
   gem build *.gemspec
   gem push *.gem
   ```

This path is for emergencies only — prefer the workflow.

## Why trusted publishing over an API key secret

- **No long-lived secret rotation.** The OIDC token is minted per workflow run and expires in minutes.
- **Repo-bound by construction.** A leaked API key in a different repo's workflow would be useless against guardrails — trusted publishing is scoped to (repo × workflow × environment).
- **Audit trail.** RubyGems records which workflow run published each version; you can confirm provenance at <https://rubygems.org/gems/ui_guardrails/versions>.

## Yanking a bad release

If a published version has a critical bug:

```bash
gem yank ui_guardrails -v X.Y.Z   # replace with the version to pull
```

Yanking removes the version from `gem install` resolution but leaves the version slot reserved — you can't republish a yanked version number. Bump and re-release.
