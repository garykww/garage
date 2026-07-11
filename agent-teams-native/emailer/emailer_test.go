package emailer

import (
	"strings"
	"testing"
)

func TestEnqueueAndPending(t *testing.T) {
	q := NewQueue()
	if err := q.Enqueue("ada@example.com", "Your receipt", "thanks!"); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	got := q.Pending()
	if len(got) != 1 || got[0].To != "ada@example.com" {
		t.Errorf("Pending() = %+v, want one message to ada@example.com", got)
	}
}

func TestEnqueueRejectsBadInput(t *testing.T) {
	q := NewQueue()
	if err := q.Enqueue("not-an-address", "subject", "body"); err == nil {
		t.Errorf("Enqueue with bad address: want error, got nil")
	}
	if err := q.Enqueue("ada@example.com", "", "body"); err == nil {
		t.Errorf("Enqueue with empty subject: want error, got nil")
	}
}

// TestRenderReceiptHTMLEscapesXSS is the regression test for the stored-XSS
// bug: a "<script>" payload in either the customer name or a receipt line
// must be HTML-escaped, never rendered as a live tag. This fails against the
// old fmt.Sprintf implementation and passes on the html/template rewrite.
func TestRenderReceiptHTMLEscapesXSS(t *testing.T) {
	const payload = "<script>alert('xss')</script>"

	t.Run("customer name", func(t *testing.T) {
		got := RenderReceiptHTML(payload, []string{"Widget x1"}, 9.99)
		if strings.Contains(got, "<script>") {
			t.Errorf("customer name rendered unescaped, output contained a live <script> tag:\n%s", got)
		}
		if !strings.Contains(got, "&lt;script&gt;") {
			t.Errorf("customer name was not HTML-escaped, want &lt;script&gt; in:\n%s", got)
		}
	})

	t.Run("receipt line", func(t *testing.T) {
		got := RenderReceiptHTML("Ada", []string{payload}, 9.99)
		if strings.Contains(got, "<script>") {
			t.Errorf("receipt line rendered unescaped, output contained a live <script> tag:\n%s", got)
		}
		if !strings.Contains(got, "&lt;script&gt;") {
			t.Errorf("receipt line was not HTML-escaped, want &lt;script&gt; in:\n%s", got)
		}
	})
}

// TestRenderReceiptHTMLPreservesContent checks the receipt still contains the
// benign customer name, line, and formatted total after the rewrite.
func TestRenderReceiptHTMLPreservesContent(t *testing.T) {
	got := RenderReceiptHTML("Ada", []string{"Widget x1", "Gadget x2"}, 42.5)
	for _, want := range []string{"Receipt for Ada", "<li>Widget x1</li>", "<li>Gadget x2</li>", "Total: $42.50"} {
		if !strings.Contains(got, want) {
			t.Errorf("receipt missing %q in:\n%s", want, got)
		}
	}
}
