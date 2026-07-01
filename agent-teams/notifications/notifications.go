package notifications

import "fmt"

type Notification struct {
	ID         string
	Recipient  string
	Message    string
	Status     string
	RetryCount int
}

type Registry struct {
	notifications map[string]*Notification
}

func NewRegistry() *Registry {
	return &Registry{notifications: make(map[string]*Notification)}
}

func (r *Registry) Queue(id, recipient, message string) *Notification {
	n := &Notification{ID: id, Recipient: recipient, Message: message, Status: "queued"}
	r.notifications[id] = n
	return n
}

func (r *Registry) Get(id string) (*Notification, error) {
	n, ok := r.notifications[id]
	if !ok {
		return nil, fmt.Errorf("unknown notification: %s", id)
	}
	return n, nil
}

func (r *Registry) MarkSent(id string) error {
	n, err := r.Get(id)
	if err != nil {
		return err
	}
	n.Status = "sent"
	return nil
}

// IncrementRetry adds by to the notification's retry count and returns the
// new count. It returns an error, without mutating the notification, if by
// is negative.
func (r *Registry) IncrementRetry(id string, by int) (int, error) {
	if by < 0 {
		return 0, fmt.Errorf("IncrementRetry: by must be non-negative, got %d", by)
	}
	n, err := r.Get(id)
	if err != nil {
		return 0, err
	}
	n.RetryCount += by
	return n.RetryCount, nil
}
