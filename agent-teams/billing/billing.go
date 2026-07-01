// Package billing is a small in-memory invoice ledger. It is the second
// module in the agent-teams showcase, owned exclusively by the
// `billing-code-agent` subagent — see .claude/agents/billing-code-agent.md and
// TASKS.md for the backlog of problems planted in this file on purpose.
package billing

import "fmt"

type LineItem struct {
	Description string
	Amount      float64
	Qty         int
}

type Invoice struct {
	ID        string
	Customer  string
	LineItems []LineItem
	Status    string
}

type Ledger struct {
	invoices map[string]*Invoice
}

func NewLedger() *Ledger {
	return &Ledger{invoices: make(map[string]*Invoice)}
}

func (l *Ledger) CreateInvoice(id, customer string) *Invoice {
	inv := &Invoice{ID: id, Customer: customer, Status: "open"}
	l.invoices[id] = inv
	return inv
}

func (l *Ledger) Get(id string) (*Invoice, error) {
	inv, ok := l.invoices[id]
	if !ok {
		return nil, fmt.Errorf("unknown invoice: %s", id)
	}
	return inv, nil
}

func (l *Ledger) AddLineItem(invoiceID, description string, amount float64, qty int) error {
	inv, err := l.Get(invoiceID)
	if err != nil {
		return err
	}
	inv.LineItems = append(inv.LineItems, LineItem{Description: description, Amount: amount, Qty: qty})
	return nil
}

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

func (l *Ledger) ApplyLateFee(invoiceID string, feePercent float64) (float64, error) {
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

func (l *Ledger) MarkPaid(invoiceID string) error {
	inv, err := l.Get(invoiceID)
	if err != nil {
		return err
	}
	inv.Status = "paid"
	return nil
}

// RenderInvoiceHTML renders an invoice as an HTML fragment for emailing or
// display in a browser.
func (l *Ledger) RenderInvoiceHTML(invoiceID string) (string, error) {
	inv, err := l.Get(invoiceID)
	if err != nil {
		return "", err
	}
	html := fmt.Sprintf("<h1>Invoice %s</h1><p>Customer: %s</p><ul>", inv.ID, inv.Customer)
	for _, li := range inv.LineItems {
		html += fmt.Sprintf("<li>%s: $%.2f x %d</li>", li.Description, li.Amount, li.Qty)
	}
	html += "</ul>"
	return html, nil
}
