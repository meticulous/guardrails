# Visual-diff integration

Guardrails consumes screenshot-diff tool output and folds findings into the unified audit report — same pattern as [deep a11y](A11Y.md). Guardrails doesn't bundle a browser or run screenshots itself; your existing visual-regression toolchain produces the artifacts, we provide the merge + report + exit-code contract.

The shipped adapter in 0.8.0 is **snap_diff-capybara** (the Rails-native gem; commits baselines to git under `doc/screenshots/`). A BackstopJS adapter is tracked in [issue #15](https://github.com/meticulous/guardrails/issues/15).

## Quick start

In a Rails app with `snap_diff-capybara` installed and system tests that call `screenshot "name"`:

```bash
# Run your system tests as usual — snap_diff writes baselines/diffs
# under doc/screenshots/ when assertions fail:
bundle exec rspec spec/system/

# Then fold the visual-diff findings into the unified audit:
VISUAL_DIFF=1 bundle exec rake guardrails:audit

# Or run the visual check standalone:
bundle exec rake guardrails:visual:deep
```

If the diffs sit somewhere other than `doc/screenshots/`:

```bash
VISUAL_DIFF_DIR=spec/screenshots bundle exec rake guardrails:visual:deep
```

To tolerate small mismatches (when the adapter emits a numeric ratio — snap_diff currently emits only a binary pass/fail, see "Adapter limits" below):

```bash
VISUAL_DIFF_THRESHOLD=0.02 bundle exec rake guardrails:audit
```

## Configuration

### Embedded (Gemfile install) — Rails initializer

Drop a `config/initializers/guardrails.rb`:

```ruby
Guardrails.configure do |c|
  c.visual_diff.enabled       = true
  c.visual_diff.adapter       = :snap_diff           # default
  c.visual_diff.snap_diff_dir = "spec/screenshots"   # default: doc/screenshots
  c.visual_diff.threshold     = 0.02                 # default: 0.0 (strict)
end
```

With `enabled = true`, `rake guardrails:audit` always runs the visual-diff check; no need to set `VISUAL_DIFF=1` on each invocation.

### Sidecar (no Gemfile change) — environment variables

| Var | Effect |
|---|---|
| `VISUAL_DIFF=1` | Enable visual-diff on `rake guardrails:audit` (the standalone `guardrails:visual:deep` task is always enabled). |
| `VISUAL_DIFF_DIR=path` | Override the snap_diff baseline directory (default `doc/screenshots`). |
| `VISUAL_DIFF_THRESHOLD=0.02` | Per-finding mismatch ratio above which the audit fails. Currently only meaningful for adapters that emit numeric ratios — snap_diff is binary. |

Env always overrides Configuration.

## How the snap_diff adapter works

The snap_diff-capybara gem commits baseline screenshots to git under `doc/screenshots/<name>.png` and, on test failure, writes a sibling `<name>.diff.png` (changed pixels in red) plus a `<name>.heatmap.diff.png` (variance density). Tests fail on baseline mismatches in CI, so the diff files are an artifact of "this regression slipped through to the artifact directory."

Guardrails walks the configured directory recursively, pairs each `<name>.diff.png` with its baseline `<name>.png`, and emits one finding per pair. `.heatmap.diff.png` files are excluded (visualization companions, not separate findings).

Each finding carries:

| Field | Source |
|---|---|
| `scenario` | Path under the screenshots dir, sans `.diff.png` (`checkout/cart` for `doc/screenshots/checkout/cart.diff.png`). |
| `baseline_path` | Sibling `<name>.png` path, relative to the repo root. |
| `diff_path` | The `.diff.png` path. |
| `mismatch_ratio` / `viewport` / `url` / `selector` / `current_path` | All `nil` for snap_diff — see "Adapter limits". |

## Adapter limits (snap_diff)

- **No mismatch percentage.** snap_diff is binary at the filesystem layer — either a `.diff.png` exists (failed) or it doesn't (passed). `Guardrails::VisualDiff` treats `nil` mismatch_ratio as "unconditionally failing", so the audit fails on any diff regardless of the configured threshold. Tracked upstream — when snap_diff-capybara adds a `snap_diff_report.json` companion (or equivalent) we'll wire mismatch percentages through.
- **No URL / viewport / selector.** Those live in snap_diff's Capybara tests, not the artifact tree. Adapters that have them (BackstopJS, issue #15) populate the optional fields.

## JSON output

When `FORMAT=json` is set on `guardrails:audit`, visual-diff findings appear under `visual_diff:`:

```json
{
  "summary": {
    "...": "...",
    "visual_diff": 2
  },
  "visual_diff": [
    {
      "scenario": "checkout/cart",
      "viewport": null,
      "mismatch_ratio": null,
      "baseline_path": "doc/screenshots/checkout/cart.png",
      "current_path": null,
      "diff_path": "doc/screenshots/checkout/cart.diff.png",
      "url": null,
      "selector": null
    }
  ]
}
```

## CI

A complete CI loop, end-to-end:

```yaml
- name: System tests (snap_diff captures baselines/diffs)
  run: bundle exec rspec spec/system/
  continue-on-error: true  # don't fail the job here — let Guardrails report

- name: Guardrails audit
  run: VISUAL_DIFF=1 bundle exec rake guardrails:audit FORMAT=json > findings.json

- name: Upload findings + diff images
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: guardrails
    path: |
      findings.json
      doc/screenshots/**/*.diff.png
```

## Why parse-only

Bundling axe-core for deep a11y would have meant bundling Capybara + headless Chrome. We didn't, and 0.6.0 shipped a parser instead. Visual-diff is the same trade: bundling Playwright/Chromium would inflate the install footprint for users who don't run system tests. Users who do run system tests already have a screenshot tool; Guardrails layers on top.

See the full evaluation: [`doc/RESEARCH-visual-diff.md`](RESEARCH-visual-diff.md).
