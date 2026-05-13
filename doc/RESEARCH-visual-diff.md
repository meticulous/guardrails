# Visual-diff integration — research memo

> Status: research, not implementation. Closes the V2 visual-diff item's "evaluate a stable visual-regression target" prerequisite before any code lands.
>
> Last updated: 2026-05-10

## Executive summary

**Recommendation: ship a `Guardrails::VisualDiff` parser that consumes screenshot-diff tool output, the same way `Guardrails::A11yDeep` consumes axe-core JSON.** Don't bundle Chromium / Playwright / Capybara as runtime deps — that was the constraint that originally parked this item, and it hasn't changed.

The cleanest external producers to support, in priority order:

1. **`snap_diff-capybara`** (formerly `capybara-screenshot-diff`) — the Rails-native default. Active gem (1.12.0 released April 2026), commits baselines to git, no cloud dep. Highest fit-for-purpose.
2. **BackstopJS** — fully OSS, clean JSON output. Worth a second adapter for non-Rails-monolith projects (the Avo dogfood pattern).
3. **Percy / Chromatic** — SaaS, vendor-locked. Defer until a user actually asks; webhook ingestion is the integration shape if they do.

The talk narrative writes itself: **static analysis catches the source, visual diff catches what the rendered DOM does next.** Pair this with `ClassItis` — AI-generated 8-class soup looks plausible in the source but pixel-shifts the baseline once a single utility is wrong.

---

## The constraint that shaped A11yDeep applies here too

When deferring deep a11y in the original roadmap, the call was:

> axe-core wrapper with `--deep` mode NOT shipped — would require Capybara + headless Chrome runtime deps.

Then in 0.6.0 we shipped `A11yDeep` as a **parser** for axe JSON output: zero new runtime deps, user runs axe however they already do, Guardrails provides the merge + report + exit-code contract. The same calculus applies to visual diff. Bundling Playwright/Chromium would balloon `bundle install` for users who don't run system tests; bundling Selenium would tie us to Ruby browser-driver decay. The right move is to consume what existing tools emit.

**Acceptance criteria for any candidate tool**, in priority order:

1. **Emits a machine-readable diff summary** — JSON, JUnit XML, or a parseable HTML/filesystem layout. We need per-scenario: name, baseline path, current path, diff path (if any), mismatch % or pass/fail, optionally the URL/component selector.
2. **Runs without Guardrails being involved.** The user's existing test toolchain runs the tool; we ingest the output. No shelling out to `npx`, no requiring the tool be present at audit time.
3. **OSS-friendly licensing** *or* a stable public API for SaaS tools.
4. **Active maintenance.** Sub-12-month release cadence and >50 GitHub stars as a rough proxy.

---

## Per-tool brief

### snap_diff-capybara (Rails-native) — **PRIMARY RECOMMENDATION**

- **What it is:** Ruby gem (formerly `capybara-screenshot-diff`, now maintained at `github.com/snap-diff/snap_diff-capybara` by `donv` and `jetthoughts`). Latest 1.12.0, April 2026. MIT-licensed. ~770k total downloads.
- **How it works:** `screenshot "name"` inside Capybara system tests. Baselines live at `doc/screenshots/` and are **committed to git** — UI changes get reviewed in PR like code. No external auth, no cloud.
- **Diff artifacts:**
  - `*.png` baseline
  - `*.diff.png` (changed pixels highlighted red)
  - `*.heatmap.diff.png` (pixel-variance density)
  - **`snap_diff_report.html`** — interactive multi-view dashboard
- **CI flow:** Tests fail on baseline mismatch. There's a reusable GitHub Actions workflow that uploads the HTML report and posts PR comments. Ships its own baseline-update flow.
- **Runtime:** Ruby 3.2+, any Capybara-compatible driver (Selenium / Playwright / Cuprite). libvips 8.9+ for fast comparisons, falls back to ChunkyPNG.
- **For Guardrails to consume:** the HTML report has a fixed structure, but the gem doesn't (yet) emit a top-level JSON summary. **Either:**
  - **(a)** ask upstream for a `snap_diff_report.json` companion to the HTML — small ask, this is the maintained gem
  - **(b)** walk `doc/screenshots/` ourselves: pair `name.png` with `name.diff.png`, treat presence of the diff file as a failing finding
- **Fit:** ★★★★★. Same ecosystem (Ruby/Rails/Capybara), no new deps for users already running system tests, baselines-in-git matches the Guardrails ethos of "the source is the source of truth."

### BackstopJS

- **What it is:** Node CLI, MIT-licensed, actively maintained, the dominant OSS visual-regression tool outside the Storybook ecosystem.
- **How it works:** `backstop init`, `backstop test`, `backstop approve`. Configured via `backstop.json` (scenarios = URL × viewport × selector). Headless Chrome via Puppeteer or Firefox/WebKit via Playwright. All artifacts local under `backstop_data/`.
- **Output:** HTML interactive report, **JSON report**, JUnit XML, CLI text. Exit 0/1.
- **For Guardrails to consume:** The JSON report already exists and is the canonical machine-readable output. Per-scenario: name, label, mismatch percentage, pass/fail, paths to reference + test + diff images.
- **Fit:** ★★★★☆. Native machine-readable output, no SaaS dep, but Node-only — Ruby/Rails shops would have a parallel toolchain. Justifiable for the "Rails frontend that already runs JS tooling" subset (any non-trivial Rails app).

### Playwright `toHaveScreenshot` / `toMatchSnapshot`

- **What it is:** Built-in Playwright assertion. The team that maintains Playwright also maintains Chromatic (Microsoft → Storybook acquisition), so it's becoming the de facto cross-tool snapshot mechanism.
- **How it works:** `await expect(page).toHaveScreenshot()`. Stores baselines in `__screenshots__/`. Updates via `--update-snapshots`.
- **Output:** JUnit / JSON via Playwright's reporter API; HTML report; per-test pass/fail in CI.
- **For Guardrails to consume:** Playwright JSON reporter emits a structured test-result document; each failure includes `attachments` with the diff image path. Parseable, but the schema is "Playwright test results" not "visual diff" — we'd be extracting the visual subset.
- **Fit:** ★★★☆☆. Future-proof and increasingly canonical, but the integration is heavier (have to filter Playwright results for screenshot-specific failures). Worth supporting in v2 of the adapter.

### Percy (BrowserStack)

- **What it is:** SaaS, all builds go through Percy's cloud. Originally a standalone product, BrowserStack-acquired in 2020.
- **Ruby story:** `percy-capybara` gem exists. Latest release v5.0.0 — July 2021 — i.e. **maintenance-stale**. 4+ years without a meaningful release; the active surface is the JS SDKs.
- **Output:** Dashboard URL + per-build webhook. No local artifacts beyond the snapshot upload.
- **Pricing:** Pricing page is gated behind BrowserStack's product navigation; no clear OSS-free tier surfaced via the public site. Assume paid-only for non-trial use.
- **For Guardrails to consume:** `build-finished` webhook payload is the integration shape — but that requires a receiver, which Guardrails-the-gem isn't. Could ship a parser for the webhook JSON that users POST to their CI.
- **Fit:** ★★☆☆☆. Stale Ruby SDK, vendor-locked, no clear OSS pricing. Defer until a user asks specifically.

### Chromatic

- **What it is:** SaaS, made by the Storybook team. The standard visual-regression for Storybook-based component libraries; expanded to Playwright + Cypress in 2024–25.
- **Ruby story:** None. JS-ecosystem only. No Lookbook integration despite Lookbook being the Rails-shaped Storybook equivalent.
- **Output:** Cloud dashboard, web API for build status, no local artifacts.
- **Pricing:** Free tier (5,000 snapshots/month, Chrome-only) — generous. Paid starts at $179/mo. "Building in the open?" OSS plan available on application.
- **Fit:** ★★☆☆☆ for Rails apps without Storybook. ★★★★☆ for ViewComponent shops who use Storybook for non-Rails components alongside. Pair-of-tools story is workable but indirect; Lookbook integration would be the missing link, and that's a Lookbook upstream ask, not a Guardrails one.

### Honorable mentions

- **Loki** — Storybook-only, narrow audience for Rails-flavored Guardrails. Skip.
- **`reg-suit`** — Cloud or self-hosted, language-agnostic, JSON report. Reasonable BackstopJS-alternative; not common enough in Rails shops to justify a dedicated adapter at v1.

---

## Fit table

| Tool | OSS | Rails-native | Machine-readable output | Cloud dep | Active | Fit score |
|---|---|---|---|---|---|---|
| snap_diff-capybara | ✅ MIT | ✅ Ruby gem | 🟡 HTML report (no JSON yet) | ❌ baselines in git | ✅ active | ★★★★★ |
| BackstopJS | ✅ MIT | ❌ Node | ✅ JSON report | ❌ local FS | ✅ active | ★★★★☆ |
| Playwright snapshots | ✅ Apache | ❌ Node | ✅ JSON via reporter | ❌ local FS | ✅ active | ★★★☆☆ |
| Percy | 🔒 SaaS | 🟡 stale gem (2021) | ✅ webhook | ✅ required | 🟡 webhooks active, SDK stale | ★★☆☆☆ |
| Chromatic | 🔒 SaaS | ❌ JS-only | ✅ API | ✅ required | ✅ active | ★★☆☆☆ |

---

## Proposed integration shape (mirrors A11yDeep)

```
lib/guardrails/visual_diff.rb           — parser + report
lib/guardrails/visual_diff/snap_diff.rb — adapter for snap_diff-capybara
lib/guardrails/visual_diff/backstop.rb  — adapter for BackstopJS JSON
spec/guardrails/visual_diff_spec.rb
spec/guardrails/visual_diff/snap_diff_spec.rb
spec/guardrails/visual_diff/backstop_spec.rb
```

Normalized `Finding` shape (across both adapters):

```ruby
Finding = Struct.new(
  :scenario,        # "homepage", "checkout_cart"
  :viewport,        # "desktop"; nil if not applicable
  :mismatch_ratio,  # Float 0.0..1.0 (or nil for snap_diff which is pass/fail)
  :baseline_path,   # relative path on disk
  :current_path,    # relative path on disk
  :diff_path,       # relative path to .diff.png, nil if pass
  :url,             # optional, BackstopJS scenarios have URLs
  :selector,        # optional
  keyword_init: true
)
```

Rake task (mirrors `guardrails:a11y:deep`):

```bash
# Either auto-detect from `doc/screenshots/` (snap_diff convention) ...
bundle exec rake guardrails:visual:deep

# ... or point at an explicit producer:
SNAP_DIFF_DIR=doc/screenshots bundle exec rake guardrails:visual:deep
BACKSTOP_JSON=backstop_data/html_report/jsonReport.json bundle exec rake guardrails:visual:deep
```

Folded into `guardrails:audit` via `VISUAL_DIFF=...` env var, same shape as `AXE_JSON`.

JSON output extends the existing audit payload:

```json
{
  "summary": { "...": "...", "visual_diff": 3 },
  "visual_diff": [
    { "scenario": "checkout/cart", "mismatch_ratio": 0.082,
      "baseline_path": "doc/screenshots/checkout_cart.png",
      "diff_path": "doc/screenshots/checkout_cart.diff.png" }
  ]
}
```

Exit-code contract: a finding's `mismatch_ratio > threshold` (configurable, default `0.0` — any diff fails) bumps the audit to exit 1. For snap_diff (pass/fail), any failure is a fail.

---

## What this buys the gem (and the talk)

1. **Closes V2.** Roadmap is fully shipped on the three core items.
2. **Talk narrative is now four layers deep:**
   - *Static AST drift* (V0): the source-level mistakes.
   - *Structural drift* (V2 cross-codebase + class-itis): the patterns the source shouldn't have.
   - *Runtime a11y drift* (V1.6 deep a11y): what the static checks can't see.
   - *Visual drift* (V2 visual-diff): what the rendered DOM does next.

   AI assistants fail at each layer differently. Each Guardrails detector maps to a specific failure mode.

3. **Same install/run story as everything else.** No new install footprint. Users keep their preferred screenshot tool; Guardrails provides the unified report.

---

## Open decisions for the morning

1. **Primary adapter: snap_diff or BackstopJS?**
   - My read: snap_diff-capybara, since (a) Rails-native, (b) we'd be working with the maintainers of a small focused gem who'd likely accept a JSON-output PR upstream, and (c) baselines-in-git matches Guardrails' "source is canonical" ethos.
   - The risk: snap_diff doesn't currently emit JSON, so v0.8.0 might need an upstream contribution. We could ship the filesystem-walking adapter first (look at `doc/screenshots/*.diff.png`) and contribute the JSON emitter separately.

2. **Scope: ship one adapter or two?**
   - One (snap_diff) keeps the PR small and proves the pattern.
   - Two (snap_diff + BackstopJS) covers the Avo / non-Rails-monolith case from day one.
   - I'd ship one and tag, then add BackstopJS in a follow-up if there's signal.

3. **Threshold default: `0.0` (any diff fails) or something more lenient?**
   - A11yDeep defaulted to "any non-nil impact fails". The visual-diff equivalent is "any pixel mismatch fails" — strict, but visual diff is opt-in (you set up baselines deliberately), so strict is the right default.
   - Per-call override via `VISUAL_DIFF_THRESHOLD=0.01` env or `visual_diff.threshold` in `guardrails.yml`.

4. **Where does this surface in the Lookbook panel?**
   - `ComponentReport#for` could add `visual_diff: [...]` showing per-component baseline mismatches. Pulls together: "this component drifted statically (raw_color) AND visually (3% mismatch on the desktop viewport)."
   - Probably out of scope for v0.8.0 — first land the audit/CI integration, layer Lookbook in v0.9.0.

5. **Is this 0.8.0 or 1.0.0?**
   - Argument for 0.8.0: matches the pattern of every other increment.
   - Argument for 1.0.0: with this shipped, all three V0–V2 column-headers are done. We could draw the "ready for serious use" line here and tag a 1.0.0.
   - My read: 0.8.0 for the visual-diff feature, then a separate 1.0.0 release after dogfooding the full V2 surface against Patchvault/Talos/Forem/Avo. The 0.2.x→0.7.x cadence already moved through dogfood-driven patches; another round before 1.0.0 fits.

---

## Out of scope

- **Running the screenshot tool ourselves.** Not now, possibly not ever — the gem's ethos is parse-only.
- **Hosted baseline storage.** Baselines stay in the user's repo (snap_diff convention) or wherever their existing tool puts them.
- **Image-diff algorithm work.** Pixel comparison is a solved problem with multiple good libraries; we don't add value by reinventing it.
- **Real-browser rendering.** Same as the headless Chrome reasoning in A11yDeep.

---

## What's needed to start

If we go with snap_diff-capybara as the primary adapter:

1. Decide if we file an upstream PR to add `snap_diff_report.json` emission, or build the filesystem-walking adapter first.
2. Add `snap_diff-capybara` to `examples/demo/Gemfile` and seed a couple of system tests so the integration spec has something to verify against.
3. Roughly 3 slices, mirroring the A11yDeep PR:
   - Slice 1: `VisualDiff` parser + `Finding` struct + snap_diff adapter + spec
   - Slice 2: rake task wiring (standalone + `guardrails:audit` fold-in) + JSON output extension
   - Slice 3: docs (new `doc/VISUAL-DIFF.md` mirroring `doc/A11Y.md`) + ROADMAP + CHANGELOG → 0.8.0

Estimated scope: a single PR, comparable to 0.6.0's `A11yDeep` (~17 specs, ~400 LOC). Could be shipped same day as kick-off if no upstream blocker.
