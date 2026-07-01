package catalog

import (
	"fmt"
	"strings"
)

type Product struct {
	SKU   string
	Name  string
	Price float64
	Tags  []string
}

type Registry struct {
	products map[string]*Product
}

func NewRegistry() *Registry {
	return &Registry{products: make(map[string]*Product)}
}

func (r *Registry) AddProduct(sku, name string, price float64, tags []string) *Product {
	p := &Product{SKU: sku, Name: name, Price: price, Tags: tags}
	r.products[sku] = p
	return p
}

func (r *Registry) Get(sku string) (*Product, error) {
	p, ok := r.products[sku]
	if !ok {
		return nil, fmt.Errorf("unknown product: %s", sku)
	}
	return p, nil
}

// UpdatePrice sets the price of the product identified by sku. It returns
// an error and leaves the product unmodified if the sku is unknown or if
// price is negative.
func (r *Registry) UpdatePrice(sku string, price float64) error {
	p, err := r.Get(sku)
	if err != nil {
		return err
	}
	if price < 0 {
		return fmt.Errorf("invalid price for %s: %f must not be negative", sku, price)
	}
	p.Price = price
	return nil
}

// Search returns every product whose name contains query as a
// case-insensitive substring.
func (r *Registry) Search(query string) []*Product {
	query = strings.ToLower(query)
	var results []*Product
	for _, p := range r.products {
		if strings.Contains(strings.ToLower(p.Name), query) {
			results = append(results, p)
		}
	}
	return results
}
