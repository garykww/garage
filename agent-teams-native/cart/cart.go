// Package cart is a small in-memory shopping-cart ledger, one of the
// target modules for the agent-teams-native showcase. Bugs and coverage
// gaps are planted on purpose — see BACKLOG.md — so a native agent team
// has real work to claim.
package cart

import "fmt"

// Item is one cart line: a product, how many of it, and the unit price.
type Item struct {
	ProductID string
	Qty       int
	UnitPrice float64
}

// Cart accumulates items for one customer ahead of checkout.
type Cart struct {
	Customer string
	Items    []Item
}

// New returns an empty cart for the named customer.
func New(customer string) (*Cart, error) {
	if customer == "" {
		return nil, fmt.Errorf("cart: customer must not be empty")
	}
	return &Cart{Customer: customer}, nil
}

// AddItem appends a line to the cart. It rejects an empty productID, a
// non-positive qty, and a negative unitPrice so that an invalid line can
// never be stored and silently skew Total.
func (c *Cart) AddItem(productID string, qty int, unitPrice float64) error {
	if productID == "" {
		return fmt.Errorf("cart: productID must not be empty")
	}
	if qty <= 0 {
		return fmt.Errorf("cart: qty must be positive, got %d", qty)
	}
	if unitPrice < 0 {
		return fmt.Errorf("cart: unitPrice must not be negative, got %v", unitPrice)
	}
	c.Items = append(c.Items, Item{ProductID: productID, Qty: qty, UnitPrice: unitPrice})
	return nil
}

// RemoveItem deletes the first line whose ProductID matches and reports
// whether a line was removed.
func (c *Cart) RemoveItem(productID string) bool {
	for i, it := range c.Items {
		if it.ProductID == productID {
			c.Items = append(c.Items[:i], c.Items[i+1:]...)
			return true
		}
	}
	return false
}

// Total returns the sum of Qty × UnitPrice across every line.
func (c *Cart) Total() float64 {
	var sum float64
	for _, it := range c.Items {
		sum += float64(it.Qty) * it.UnitPrice
	}
	return sum
}
