// Package billing is a small in-memory invoice ledger. It is the second
// module in the subagent-teams showcase, owned exclusively by the
// `billing-code-agent` subagent — see .claude/agents/billing-code-agent.md and
// TASKS.md for the backlog of problems planted in this file on purpose.
package billing

import (
	"fmt"
	"html/template"
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
type Invoice struct {
	ID        string
	Customer  string
	LineItems []LineItem
	Status    string
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

// Get looks up the invoice with the given id. It returns an error if no
// invoice with that id has been created.
func (l *Ledger) Get(id string) (*Invoice, error) {
	inv, ok := l.invoices[id]
	if !ok {
		return nil, fmt.Errorf("unknown invoice: %s", id)
	}
	return inv, nil
}

// AddLineItem appends a line item to the invoice identified by invoiceID.
// amount is the per-unit price and must not be negative; qty must be
// greater than zero. Either violation returns a descriptive error and adds
// no line item.
func (l *Ledger) AddLineItem(invoiceID, description string, amount float64, qty int) error {
	inv, err := l.Get(invoiceID)
	if err != nil {
		return err
	}
	if amount < 0 {
		return fmt.Errorf("invalid amount for line item %q: %v, must be >= 0", description, amount)
	}
	if qty <= 0 {
		return fmt.Errorf("invalid qty for line item %q: %d, must be > 0", description, qty)
	}
	inv.LineItems = append(inv.LineItems, LineItem{Description: description, Amount: amount, Qty: qty})
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
// summing the invoice. quantity must be greater than zero and unitPrice
// must not be negative; either violation returns an error and no line item
// is added.
func (l *Ledger) AddSaleLineItem(invoiceID string, itemID string, quantity int, unitPrice float64) error {
	if quantity <= 0 {
		return fmt.Errorf("invalid quantity for item %s: %d, must be > 0", itemID, quantity)
	}
	if unitPrice < 0 {
		return fmt.Errorf("invalid unit price for item %s: %v, must be >= 0", itemID, unitPrice)
	}
	description := fmt.Sprintf("Item %s", itemID)
	return l.AddLineItem(invoiceID, description, unitPrice, quantity)
}

// Total computes the current sum of Amount * Qty across all of the
// invoice's line items. It returns an error if the invoice does not exist.
func (l *Ledger) Total(invoiceID string) (float64, error) {
	inv, err := l.Get(invoiceID)
	if err != nil {
		return 0, err
	}
	total := 0.0
	for _, li := range inv.LineItems {
		total += li.Amount * float64(li.Qty)
	}
	return total, nil
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
	inv, err := l.Get(invoiceID)
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
	inv, err := l.Get(invoiceID)
	if err != nil {
		return "", err
	}
	items := make([]renderLineItem, len(inv.LineItems))
	for i, li := range inv.LineItems {
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
