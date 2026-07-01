// Package billing is a small in-memory invoice ledger. It is the second
// module in the agent-teams showcase, owned exclusively by the
// `billing-code-agent` subagent — see .claude/agents/billing-code-agent.md and
// TASKS.md for the backlog of problems planted in this file on purpose.
package billing

import (
	"fmt"
	"html/template"
	"math"
	"strings"
)

// LineItem is a single billable entry on an Invoice: a description, a
// per-unit Amount, and the Qty (quantity) purchased. An invoice's total is
// the sum of Amount * Qty across all of its line items.
type LineItem struct {
	Description string
	Amount      float64
	Qty         int
}

// Invoice tracks the line items billed to a single Customer under one ID,
// along with its current Status (e.g. "open" or "paid").
//
// The line items themselves are deliberately unexported: LineItem values may
// only be constructed through AddLineItem/AddSaleLineItem, which validate
// Amount and Qty before they can ever land in an invoice's total. If the
// slice were exported, any caller holding an *Invoice could append a
// malformed LineItem (e.g. Amount: math.Inf(1)) directly, bypassing that
// validation entirely. Use the LineItems method to read a safe copy.
type Invoice struct {
	ID        string
	Customer  string
	lineItems []LineItem
	Status    string
}

// LineItems returns a copy of the invoice's line items. Callers may read or
// hold the returned slice freely; mutating it (or appending to it) has no
// effect on the invoice itself. To add a line item, use
// Ledger.AddLineItem or Ledger.AddSaleLineItem instead.
func (inv *Invoice) LineItems() []LineItem {
	items := make([]LineItem, len(inv.lineItems))
	copy(items, inv.lineItems)
	return items
}

// Ledger is an in-memory store of invoices, keyed by invoice ID. The zero
// value is not usable; construct one with NewLedger.
type Ledger struct {
	invoices map[string]*Invoice
}

// NewLedger returns an empty, ready-to-use Ledger.
func NewLedger() *Ledger {
	return &Ledger{invoices: make(map[string]*Invoice)}
}

// CreateInvoice creates and stores a new Invoice with the given id and
// customer, defaulting its Status to "open", and returns it. If an invoice
// with the same id already exists, it is overwritten.
func (l *Ledger) CreateInvoice(id, customer string) *Invoice {
	inv := &Invoice{ID: id, Customer: customer, Status: "open"}
	l.invoices[id] = inv
	return inv
}

// get returns the ledger's live, mutable *Invoice for internal use by
// Ledger's own methods (AddLineItem, MarkPaid, Total, RenderInvoiceHTML).
// It is unexported on purpose: only code inside this package may obtain the
// live pointer, so external callers can never mutate a stored invoice's
// fields directly — see Get for the safe, exported alternative.
func (l *Ledger) get(id string) (*Invoice, error) {
	inv, ok := l.invoices[id]
	if !ok {
		return nil, fmt.Errorf("unknown invoice: %s", id)
	}
	return inv, nil
}

// Get looks up the invoice with the given id and returns a copy of it. It
// returns an error if no invoice with that id has been created.
//
// The returned *Invoice is a copy, not the ledger's stored invoice: mutating
// its fields, or the slice returned by its LineItems method, has no effect
// on the invoice held by the ledger. This closes off a bypass where a caller
// could otherwise take the pointer returned here and append a malformed,
// unvalidated LineItem straight into the invoice, sidestepping
// AddLineItem/AddSaleLineItem's validation entirely. Use
// AddLineItem/AddSaleLineItem/MarkPaid to make changes.
func (l *Ledger) Get(id string) (*Invoice, error) {
	inv, err := l.get(id)
	if err != nil {
		return nil, err
	}
	cp := *inv
	cp.lineItems = append([]LineItem(nil), inv.lineItems...)
	return &cp, nil
}

// MaxLineItemAmount is the largest per-unit price accepted by AddLineItem and
// AddSaleLineItem. It bounds the magnitude of any single caller-supplied
// value so that Total's integer-cents accumulation (see Total) stays well
// within int64 range and can never be pushed toward +Inf or lose precision,
// even across many line items on one invoice. Values above this bound (or
// non-finite values: NaN, +Inf, -Inf) are rejected with an error and no line
// item is added.
const MaxLineItemAmount = 1_000_000_000 // e.g. $1,000,000,000 per unit

// MaxLineItemQty is the largest quantity accepted by AddLineItem and
// AddSaleLineItem, for the same overflow/precision reasons as
// MaxLineItemAmount.
const MaxLineItemQty = 1_000_000

// AddLineItem appends a line item to the invoice identified by invoiceID.
// amount is the per-unit price and must be a finite number in the range
// [0, MaxLineItemAmount]; qty must be an integer in the range
// (0, MaxLineItemQty]. Any violation returns a descriptive error and adds no
// line item.
func (l *Ledger) AddLineItem(invoiceID, description string, amount float64, qty int) error {
	inv, err := l.get(invoiceID)
	if err != nil {
		return err
	}
	if math.IsNaN(amount) || math.IsInf(amount, 0) {
		return fmt.Errorf("invalid amount for line item %q: %v, must be a finite number", description, amount)
	}
	if amount < 0 {
		return fmt.Errorf("invalid amount for line item %q: %v, must be >= 0", description, amount)
	}
	if amount > MaxLineItemAmount {
		return fmt.Errorf("invalid amount for line item %q: %v, must be <= %v", description, amount, MaxLineItemAmount)
	}
	if qty <= 0 {
		return fmt.Errorf("invalid qty for line item %q: %d, must be > 0", description, qty)
	}
	if qty > MaxLineItemQty {
		return fmt.Errorf("invalid qty for line item %q: %d, must be <= %d", description, qty, MaxLineItemQty)
	}
	inv.lineItems = append(inv.lineItems, LineItem{Description: description, Amount: amount, Qty: qty})
	return nil
}

// AddSaleLineItem records a line item for an inventory sale (checkout) on
// the given invoice. It is the billing-side half of the cross-module
// checkout flow: an external caller invokes inventory's Checkout(id, qty),
// then passes the resulting CheckoutResult's ItemID, Quantity, and
// UnitPrice fields straight through to this method.
//
// unitPrice is the PER-UNIT price, not a pre-computed total — it is stored
// as-is in LineItem.Amount, and Total() multiplies Amount by Qty when
// summing the invoice. quantity must be an integer in the range
// (0, MaxLineItemQty], and unitPrice must be a finite number in the range
// [0, MaxLineItemAmount]; any violation returns an error and no line item is
// added.
func (l *Ledger) AddSaleLineItem(invoiceID string, itemID string, quantity int, unitPrice float64) error {
	if quantity <= 0 {
		return fmt.Errorf("invalid quantity for item %s: %d, must be > 0", itemID, quantity)
	}
	if quantity > MaxLineItemQty {
		return fmt.Errorf("invalid quantity for item %s: %d, must be <= %d", itemID, quantity, MaxLineItemQty)
	}
	if math.IsNaN(unitPrice) || math.IsInf(unitPrice, 0) {
		return fmt.Errorf("invalid unit price for item %s: %v, must be a finite number", itemID, unitPrice)
	}
	if unitPrice < 0 {
		return fmt.Errorf("invalid unit price for item %s: %v, must be >= 0", itemID, unitPrice)
	}
	if unitPrice > MaxLineItemAmount {
		return fmt.Errorf("invalid unit price for item %s: %v, must be <= %v", itemID, unitPrice, MaxLineItemAmount)
	}
	description := fmt.Sprintf("Item %s", itemID)
	return l.AddLineItem(invoiceID, description, unitPrice, quantity)
}

// Total computes the current sum of Amount * Qty across all of the
// invoice's line items. It returns an error if the invoice does not exist,
// or if summing the invoice's line items would overflow the internal int64
// cent accumulator (see below) — in either case the returned float64 is 0
// and must be ignored.
//
// Internally, each line item's Amount is rounded to the nearest cent and
// accumulated as an int64 cent count rather than summed as float64 dollars.
// Naively summing float64 dollar amounts accumulates binary rounding error
// as more line items are added (the classic 0.1 + 0.2 != 0.3 problem);
// rounding once per line item and then doing the summation in integer cents
// avoids that drift entirely, at the cost of assuming Amount never needs
// more than cent-level precision — true for ordinary currency values.
//
// Each individual line item's contribution to the running total is bounded
// well within int64 range by MaxLineItemAmount/MaxLineItemQty (worst case
// ~1e17 per item, vs. int64 max ~9.2e18). But an invoice can hold an
// unbounded *number* of line items, and ~93 max-magnitude items would be
// enough to silently wrap the running total past int64 max — Go integer
// overflow is silent, not a panic, so without a check it would produce a
// negative or otherwise garbage total instead of an error. The loop below
// detects that condition (every line item's contribution is >= 0, since
// AddLineItem/AddSaleLineItem reject negative amounts, so the running total
// should only ever increase; if it doesn't, it wrapped) and fails loudly
// instead.
func (l *Ledger) Total(invoiceID string) (float64, error) {
	inv, err := l.get(invoiceID)
	if err != nil {
		return 0, err
	}
	var totalCents int64
	for _, li := range inv.lineItems {
		cents := int64(math.Round(li.Amount * 100))
		itemCents := cents * int64(li.Qty)
		newTotal := totalCents + itemCents
		if itemCents > 0 && newTotal < totalCents {
			return 0, fmt.Errorf("invoice %s total overflowed while summing %d line items", invoiceID, len(inv.lineItems))
		}
		totalCents = newTotal
	}
	return float64(totalCents) / 100, nil
}

// ApplyLateFee charges a late fee of feePercent percent of the invoice's
// current total, recorded as an additional "Late fee" line item. feePercent
// must not be negative — a negative value would silently discount the
// invoice instead of charging a fee, so it is rejected up front with no
// line item added and no change to the invoice.
func (l *Ledger) ApplyLateFee(invoiceID string, feePercent float64) (float64, error) {
	if feePercent < 0 {
		return 0, fmt.Errorf("invalid feePercent for invoice %s: %v, must be >= 0", invoiceID, feePercent)
	}
	total, err := l.Total(invoiceID)
	if err != nil {
		return 0, err
	}
	fee := total * feePercent / 100
	if err := l.AddLineItem(invoiceID, "Late fee", fee, 1); err != nil {
		return 0, err
	}
	return total + fee, nil
}

// MarkPaid sets the invoice's Status to "paid". It returns an error if the
// invoice does not exist.
func (l *Ledger) MarkPaid(invoiceID string) error {
	inv, err := l.get(invoiceID)
	if err != nil {
		return err
	}
	inv.Status = "paid"
	return nil
}

// invoiceHTMLTemplate renders the same output shape RenderInvoiceHTML has
// always produced (an h1 with the invoice ID, a p with the customer, and a
// ul of line items formatted as "Description: $Amount x Qty"), but through
// html/template so that inv.ID, inv.Customer, and each line item's
// Description are HTML-escaped instead of interpolated raw.
var invoiceHTMLTemplate = template.Must(template.New("invoice").Parse(
	`<h1>Invoice {{.ID}}</h1><p>Customer: {{.Customer}}</p><ul>{{range .LineItems}}<li>{{.Description}}: ${{.AmountStr}} x {{.Qty}}</li>{{end}}</ul>`,
))

// renderLineItem is the view model passed to invoiceHTMLTemplate; it carries
// a pre-formatted amount string since html/template's default number
// formatting doesn't match the historical "%.2f" output.
type renderLineItem struct {
	Description string
	AmountStr   string
	Qty         int
}

// RenderInvoiceHTML renders an invoice as an HTML fragment for emailing or
// display in a browser. Customer-controlled strings — the customer name and
// each line item's description — are HTML-escaped via html/template so they
// cannot inject markup or script into the rendered output.
func (l *Ledger) RenderInvoiceHTML(invoiceID string) (string, error) {
	inv, err := l.get(invoiceID)
	if err != nil {
		return "", err
	}
	items := make([]renderLineItem, len(inv.lineItems))
	for i, li := range inv.lineItems {
		items[i] = renderLineItem{
			Description: li.Description,
			AmountStr:   fmt.Sprintf("%.2f", li.Amount),
			Qty:         li.Qty,
		}
	}
	data := struct {
		ID        string
		Customer  string
		LineItems []renderLineItem
	}{
		ID:        inv.ID,
		Customer:  inv.Customer,
		LineItems: items,
	}
	var buf strings.Builder
	if err := invoiceHTMLTemplate.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("rendering invoice %s: %w", invoiceID, err)
	}
	return buf.String(), nil
}
