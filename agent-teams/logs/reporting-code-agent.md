# reporting-code-agent — activity log

Format: see `logs/README.md`. Append-only, oldest entry first.

<!-- entries appended below -->

## 2026-07-01 00:00 — AverageMetric zero-division fix
**Assigned by:** lead — code-agent(reporting), task: [reporting] AverageMetric zero-division fix

**Findings:** `AverageMetric` (reporting/reporting.go:43-53, pre-fix) divided
`total` by `float64(len(rep.Metrics))` with no guard for the empty-map case.
A report created via `CreateReport` but never given any metrics (e.g. a
brand-new report queried before any `SetMetric` call) would return `NaN`
with a nil error instead of surfacing a usable error — any caller checking
only `err != nil` would silently propagate `NaN` downstream.
`reporting_test.go` (pre-fix) only covered `TestCreateReportAndSetMetric`
and `TestAverageMetric`, both of which set metrics first; the zero-metrics
path was untested (there was even a comment at reporting_test.go:34-35
flagging this gap explicitly).

**Decision:** Added an explicit `len(rep.Metrics) == 0` check in
`AverageMetric` that returns `(0, fmt.Errorf(...))` before the division,
matching the existing error-return style used elsewhere in the file (e.g.
`Get`, reporting/reporting.go:25-31). No signature change, so no callers
outside this file need updating.

**Plan:**
- Edited reporting/reporting.go (added lines after 47, before the total/len
  division) to add the zero-metrics guard ahead of the average computation.
- Added `TestAverageMetricNoMetrics` in reporting_test.go, replacing the
  placeholder comment, asserting both that an error is returned and that
  the returned value is the zero value (0), not NaN.
- Ran `go build ./reporting/... && go vet ./reporting/... && go test
  ./reporting/... -cover -v` — all 3 tests pass, 86.4% coverage:

```
=== RUN   TestCreateReportAndSetMetric
--- PASS: TestCreateReportAndSetMetric (0.00s)
=== RUN   TestAverageMetric
--- PASS: TestAverageMetric (0.00s)
=== RUN   TestAverageMetricNoMetrics
--- PASS: TestAverageMetricNoMetrics (0.00s)
PASS
coverage: 86.4% of statements
ok  	agent-teams-demo/reporting	0.282s	coverage: 86.4% of statements
```

**Result:** done
