# catalog-code-agent log

Append-only log for code-agent sessions scoped to `catalog/`. See
`logs/README.md` for format and rules.

## 2026-07-01 — UpdatePrice negative price validation
**Assigned by:** lead — code-agent(catalog), task: [catalog] UpdatePrice validation
**Findings:** `UpdatePrice` in `catalog/catalog.go:37-43` accepted any
`price` value, including negative ones, and stored it on the `Product`
unchanged with no error returned. `catalog/catalog_test.go:30-31` had an
explicit placeholder comment ("No coverage yet for UpdatePrice()")
confirming there was no regression test for this path.
**Decision:** Reject negative prices with an error and leave the existing
product untouched, rather than clamping to zero or silently ignoring the
call — this matches the pattern used elsewhere in the file (`Get` returns
an error for unknown SKUs) and gives the caller an explicit signal instead
of a silent no-op.
**Plan:**
1. Added a `price < 0` check in `UpdatePrice` (`catalog/catalog.go:40-42`)
   that returns `fmt.Errorf("invalid price for %s: %f must not be
   negative", sku, price)` before mutating `p.Price`, plus a doc comment
   for the exported method.
2. Replaced the placeholder comment in `catalog/catalog_test.go` with
   `TestUpdatePriceRejectsNegative` (asserts an error is returned and the
   original price of 19.99 is unchanged) and `TestUpdatePriceAcceptsValid`
   (asserts a valid price of 24.99 is stored with no error).
3. Ran `go build ./catalog/... && go vet ./catalog/... && go test
   ./catalog/... -v -cover` — all 4 tests pass, 90.5% coverage.
**Result:** done
