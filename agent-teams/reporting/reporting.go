package reporting

import "fmt"

type Report struct {
	ID      string
	Title   string
	Metrics map[string]float64
}

type Registry struct {
	reports map[string]*Report
}

func NewRegistry() *Registry {
	return &Registry{reports: make(map[string]*Report)}
}

func (r *Registry) CreateReport(id, title string) *Report {
	rep := &Report{ID: id, Title: title, Metrics: make(map[string]float64)}
	r.reports[id] = rep
	return rep
}

func (r *Registry) Get(id string) (*Report, error) {
	rep, ok := r.reports[id]
	if !ok {
		return nil, fmt.Errorf("unknown report: %s", id)
	}
	return rep, nil
}

func (r *Registry) SetMetric(id, name string, value float64) error {
	rep, err := r.Get(id)
	if err != nil {
		return err
	}
	rep.Metrics[name] = value
	return nil
}

// AverageMetric returns the mean of every metric recorded on the report.
func (r *Registry) AverageMetric(id string) (float64, error) {
	rep, err := r.Get(id)
	if err != nil {
		return 0, err
	}
	if len(rep.Metrics) == 0 {
		return 0, fmt.Errorf("report %s has no metrics", id)
	}
	total := 0.0
	for _, v := range rep.Metrics {
		total += v
	}
	return total / float64(len(rep.Metrics)), nil
}
