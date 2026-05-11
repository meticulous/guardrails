# Upstream issue draft — snap_diff-capybara JSON report companion

> Not filed yet. For sign-off before posting at <https://github.com/snap-diff/snap_diff-capybara/issues/new>. Delete this file after the issue is filed.

---

**Suggested title:**

```
Feature: emit a snap_diff_report.json companion to the HTML report
```

**Suggested labels:** `enhancement`, `report`

---

**Body:**

```markdown
## Context

Hi, thanks for maintaining this gem — we're integrating it into [Guardrails](https://github.com/meticulous/guardrails), a static-audit gem that consolidates Rails UI-drift findings into a single report (static a11y, view-level drift, partial similarity, ViewComponent / Stimulus audits, etc.). The latest release (0.8.0) adds a snap_diff-capybara adapter for our `Guardrails::VisualDiff` audit, walking `doc/screenshots/` for `<name>.diff.png` files and folding them into the unified report. Works well.

The one gap: we'd like per-finding **mismatch percentages** in the unified report, but the filesystem layout is binary (a `.diff.png` either exists or doesn't). Our current adapter emits `mismatch_ratio: nil` and treats nil as "unconditionally failing" — fine for snap_diff itself, but it means our `VISUAL_DIFF_THRESHOLD=0.02` knob doesn't do anything for snap_diff users (the threshold needs a numeric ratio to filter against).

## Ask

Would you be open to emitting a `snap_diff_report.json` alongside the HTML report? Something like:

```json
{
  "generated_at": "2026-05-11T08:23:14Z",
  "fail_if_new": true,
  "scenarios": [
    {
      "name": "homepage",
      "viewport": "desktop_1280",
      "passed": false,
      "mismatch_ratio": 0.0237,
      "baseline_path": "doc/screenshots/homepage.png",
      "current_path": "tmp/snap_diff/homepage.actual.png",
      "diff_path": "doc/screenshots/homepage.diff.png",
      "heatmap_path": "doc/screenshots/homepage.heatmap.diff.png"
    }
  ]
}
```

BackstopJS's `jsonReport.json` is a reasonable shape reference if you want a prior-art example.

## Why not just walk the filesystem (more)

We could read the diff PNGs ourselves to compute mismatch ratios, but that pulls libvips / ChunkyPNG into Guardrails' install footprint — and snap_diff already has the comparison data internally during its run. Keeping image work in the gem that already does image work is cleaner.

## Happy to PR

If the proposal seems reasonable, I'm happy to draft the implementation. Wanted to check on the shape and whether you'd want it gated by an opt-in config option before opening one.

Thanks again for the gem.
```
