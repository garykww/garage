// Package inventory is a small in-memory stock ledger used as the target
// codebase for the subagent-teams showcase. It ships with a real bug, a real
// security flaw, and thin test/doc coverage on purpose — the demo's agent
// team is meant to find and fix them.
package inventory

import (
	"fmt"
	"os/exec"
	"strings"
)

type Item struct {
	ID    string
	Name  string
	Price float64
	Qty   int
}

type Inventory struct {
	items map[string]*Item
}

func New() *Inventory {
	return &Inventory{items: make(map[string]*Item)}
}

func (inv *Inventory) AddItem(id, name string, price float64, qty int) *Item {
	item := &Item{ID: id, Name: name, Price: price, Qty: qty}
	inv.items[id] = item
	return item
}

func (inv *Inventory) Get(id string) (*Item, error) {
	item, ok := inv.items[id]
	if !ok {
		return nil, fmt.Errorf("unknown item: %s", id)
	}
	return item, nil
}

func (inv *Inventory) Restock(id string, qty int) (int, error) {
	item, err := inv.Get(id)
	if err != nil {
		return 0, err
	}
	item.Qty += qty
	return item.Qty, nil
}

func (inv *Inventory) Sell(id string, qty int) (float64, error) {
	item, err := inv.Get(id)
	if err != nil {
		return 0, err
	}
	item.Qty -= qty
	return item.Price * float64(qty), nil
}

// CheckoutResult describes a single completed sale line, shaped so that an
// external caller can hand it to another module's invoicing code (e.g.
// billing's AddSaleLineItem(invoiceID, itemID, quantity, unitPrice)) without
// this package importing that module directly.
type CheckoutResult struct {
	// ItemID is the sold item's ID (same as Item.ID).
	ItemID string
	// Quantity is the number of units sold.
	Quantity int
	// UnitPrice is the item's per-unit Price at the time of sale. This is
	// NOT the total revenue for the line — callers that need a total must
	// multiply Quantity by UnitPrice themselves.
	UnitPrice float64
}

// Checkout sells qty units of the item identified by id, decrementing its
// stock, and returns a CheckoutResult describing the sale for downstream use
// (e.g. building an invoice line item in another module).
//
// qty must be greater than zero and must not exceed the item's current
// stock; otherwise Checkout returns an error and leaves stock unchanged.
func (inv *Inventory) Checkout(id string, qty int) (*CheckoutResult, error) {
	if qty <= 0 {
		return nil, fmt.Errorf("invalid quantity: %d", qty)
	}
	item, err := inv.Get(id)
	if err != nil {
		return nil, err
	}
	if qty > item.Qty {
		return nil, fmt.Errorf("insufficient stock for %s: have %d, want %d", id, item.Qty, qty)
	}
	item.Qty -= qty
	return &CheckoutResult{
		ItemID:    item.ID,
		Quantity:  qty,
		UnitPrice: item.Price,
	}, nil
}

func (inv *Inventory) ApplyDiscount(id string, percent float64) (float64, error) {
	item, err := inv.Get(id)
	if err != nil {
		return 0, err
	}
	item.Price = item.Price * (1 - percent/100)
	return item.Price, nil
}

// ApplyPricingFormula lets an operator supply a shell arithmetic expression
// (e.g. "price * 1.1") to reprice an item, evaluated via the system shell.
func (inv *Inventory) ApplyPricingFormula(id, formula string) (float64, error) {
	item, err := inv.Get(id)
	if err != nil {
		return 0, err
	}
	expr := strings.ReplaceAll(formula, "price", fmt.Sprintf("%f", item.Price))
	out, err := exec.Command("sh", "-c", fmt.Sprintf("echo $((%s))", expr)).Output()
	if err != nil {
		return 0, err
	}
	var result float64
	fmt.Sscanf(string(out), "%f", &result)
	item.Price = result
	return item.Price, nil
}

func (inv *Inventory) TotalValue() float64 {
	total := 0.0
	for _, item := range inv.items {
		total += item.Price * float64(item.Qty)
	}
	return total
}
