# shipping-code-agent — activity log

Format: see `logs/README.md`. Append-only, oldest entry first.

<!-- entries appended below -->

## 2026-07-01 00:00 — EstimateCost validation for negative rate/weight
**Assigned by:** lead — code-agent(shipping), task: [shipping] EstimateCost validation
**Findings:** `EstimateCost` (shipping/shipping.go:55-61, pre-fix) computed
`s.Weight * ratePerKg` with no validation on either operand. A negative
`ratePerKg` argument or a shipment created via `CreateShipment` with a
negative `weight` (also unvalidated) silently produced a negative cost
instead of erroring. `shipping_test.go:28-29` had an explicit placeholder
comment ("No coverage yet for EstimateCost()") confirming the gap was
known but unaddressed.
**Decision:** Added two guard checks inside `EstimateCost` itself (rather
than validating in `CreateShipment`) to keep the fix minimal and scoped to
the reported function: reject `ratePerKg < 0` and reject `s.Weight < 0`,
each returning a wrapped `fmt.Errorf` and `0` cost. `CreateShipment` still
accepts any weight value uncontested — that's a separate, broader
validation gap not part of this task, so left untouched.
**Plan:** Edited shipping/shipping.go:53-70 (doc comment + two validation
checks before the multiply). Replaced the placeholder comment in
shipping_test.go:28-29 with three new tests: `TestEstimateCost` (valid
inputs, 2.5kg * 4.0/kg == 10.0), `TestEstimateCostNegativeRatePerKg`
(expects error), `TestEstimateCostNegativeWeight` (expects error). Ran `go
build ./... && go vet ./... && go test ./... -v -cover` from
shipping/ — all 5 tests pass, 84.6% coverage, no vet issues.
**Result:** done
