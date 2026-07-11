// Package payment is a small in-memory charge ledger, one of the target
// modules for the agent-teams-native showcase. Bugs and coverage gaps are
// planted on purpose — see BACKLOG.md — so a native agent team has real
// work to claim.
package payment

import "fmt"

// Charge records money captured for one order, plus any amount refunded
// against it since.
type Charge struct {
	ID       string
	OrderID  string
	Amount   float64
	Refunded float64
	Status   string // "captured" or "refunded"
}

// Processor is an in-memory charge ledger keyed by charge ID.
type Processor struct {
	charges map[string]*Charge
	nextID  int
}

// NewProcessor returns an empty Processor.
func NewProcessor() *Processor {
	return &Processor{charges: make(map[string]*Charge)}
}

// Capture records a new charge for orderID and returns the new charge's ID.
func (p *Processor) Capture(orderID string, amount float64) (string, error) {
	if orderID == "" {
		return "", fmt.Errorf("payment: orderID must not be empty")
	}
	if amount <= 0 {
		return "", fmt.Errorf("payment: amount must be positive, got %v", amount)
	}
	p.nextID++
	id := fmt.Sprintf("ch-%d", p.nextID)
	p.charges[id] = &Charge{ID: id, OrderID: orderID, Amount: amount, Status: "captured"}
	return id, nil
}

// Refund records a refund against an existing charge. The amount must be
// positive, and the cumulative refunded total must not exceed the captured
// amount. Once the refunded total reaches the captured amount, the charge's
// status flips to "refunded".
func (p *Processor) Refund(chargeID string, amount float64) error {
	ch, ok := p.charges[chargeID]
	if !ok {
		return fmt.Errorf("payment: no charge %q", chargeID)
	}
	if amount <= 0 {
		return fmt.Errorf("payment: refund amount must be positive, got %v", amount)
	}
	if ch.Refunded+amount > ch.Amount {
		return fmt.Errorf("payment: refund of %v exceeds refundable balance %v", amount, ch.Amount-ch.Refunded)
	}
	ch.Refunded += amount
	if ch.Refunded >= ch.Amount {
		ch.Status = "refunded"
	}
	return nil
}

// Get returns a copy of the charge with the given ID.
func (p *Processor) Get(chargeID string) (Charge, error) {
	ch, ok := p.charges[chargeID]
	if !ok {
		return Charge{}, fmt.Errorf("payment: no charge %q", chargeID)
	}
	return *ch, nil
}
