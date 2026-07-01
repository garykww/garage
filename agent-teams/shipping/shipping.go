package shipping

import "fmt"

type Shipment struct {
	ID      string
	OrderID string
	Carrier string
	Status  string
	Weight  float64
}

type Registry struct {
	shipments map[string]*Shipment
}

func NewRegistry() *Registry {
	return &Registry{shipments: make(map[string]*Shipment)}
}

func (r *Registry) CreateShipment(id, orderID, carrier string, weight float64) *Shipment {
	s := &Shipment{ID: id, OrderID: orderID, Carrier: carrier, Status: "pending", Weight: weight}
	r.shipments[id] = s
	return s
}

func (r *Registry) Get(id string) (*Shipment, error) {
	s, ok := r.shipments[id]
	if !ok {
		return nil, fmt.Errorf("unknown shipment: %s", id)
	}
	return s, nil
}

func (r *Registry) MarkShipped(id string) error {
	s, err := r.Get(id)
	if err != nil {
		return err
	}
	s.Status = "shipped"
	return nil
}

func (r *Registry) MarkDelivered(id string) error {
	s, err := r.Get(id)
	if err != nil {
		return err
	}
	s.Status = "delivered"
	return nil
}

// EstimateCost returns the shipping cost for a shipment at the given rate
// per kilogram. It returns an error if ratePerKg is negative or if the
// shipment's Weight is negative, rather than silently producing a negative
// cost.
func (r *Registry) EstimateCost(id string, ratePerKg float64) (float64, error) {
	s, err := r.Get(id)
	if err != nil {
		return 0, err
	}
	if ratePerKg < 0 {
		return 0, fmt.Errorf("invalid ratePerKg: %f is negative", ratePerKg)
	}
	if s.Weight < 0 {
		return 0, fmt.Errorf("invalid shipment weight: %f is negative", s.Weight)
	}
	return s.Weight * ratePerKg, nil
}
