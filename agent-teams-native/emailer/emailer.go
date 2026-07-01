// Package emailer is a small in-memory outbox, one of the target modules
// for the agent-teams-native showcase. Bugs and coverage gaps are planted
// on purpose — see BACKLOG.md — so a native agent team has real work to
// claim.
package emailer

import (
	"fmt"
	"strings"
)

// Message is one queued email.
type Message struct {
	To      string
	Subject string
	Body    string
}

// Queue is an in-memory outbox: messages are enqueued and wait for a
// sender (which this demo doesn't have) to drain them.
type Queue struct {
	pending []Message
}

// NewQueue returns an empty Queue.
func NewQueue() *Queue {
	return &Queue{}
}

// Enqueue adds a message to the outbox.
func (q *Queue) Enqueue(to, subject, body string) error {
	if to == "" || !strings.Contains(to, "@") {
		return fmt.Errorf("emailer: to must be an email address, got %q", to)
	}
	if subject == "" {
		return fmt.Errorf("emailer: subject must not be empty")
	}
	q.pending = append(q.pending, Message{To: to, Subject: subject, Body: body})
	return nil
}

// Pending returns a copy of the queued messages in enqueue order.
func (q *Queue) Pending() []Message {
	out := make([]Message, len(q.pending))
	copy(out, q.pending)
	return out
}

// RenderReceiptHTML builds the HTML body for an order receipt: the
// customer's name, one line per purchased item, and the charged total.
func RenderReceiptHTML(customer string, lines []string, total float64) string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf("<h1>Receipt for %s</h1>\n<ul>\n", customer))
	for _, line := range lines {
		b.WriteString(fmt.Sprintf("  <li>%s</li>\n", line))
	}
	b.WriteString(fmt.Sprintf("</ul>\n<p>Total: $%.2f</p>\n", total))
	return b.String()
}
