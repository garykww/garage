package loyalty

import "fmt"

type Account struct {
	ID         string
	CustomerID string
	Points     int
}

type Registry struct {
	accounts map[string]*Account
}

func NewRegistry() *Registry {
	return &Registry{accounts: make(map[string]*Account)}
}

func (r *Registry) OpenAccount(id, customerID string) *Account {
	a := &Account{ID: id, CustomerID: customerID}
	r.accounts[id] = a
	return a
}

func (r *Registry) Get(id string) (*Account, error) {
	a, ok := r.accounts[id]
	if !ok {
		return nil, fmt.Errorf("unknown account: %s", id)
	}
	return a, nil
}

func (r *Registry) EarnPoints(id string, points int) (int, error) {
	if points <= 0 {
		return 0, fmt.Errorf("invalid points for %s: must be positive, got %d", id, points)
	}
	a, err := r.Get(id)
	if err != nil {
		return 0, err
	}
	a.Points += points
	return a.Points, nil
}

// RedeemPoints deducts points from the account's balance and returns the
// new balance.
func (r *Registry) RedeemPoints(id string, points int) (int, error) {
	a, err := r.Get(id)
	if err != nil {
		return 0, err
	}
	a.Points -= points
	return a.Points, nil
}
