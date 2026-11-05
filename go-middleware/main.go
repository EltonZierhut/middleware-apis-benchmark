// go-middleware: implementação de referência do middleware de APIs em Go (stdlib).
//
// Rotas (mesmo contrato da versão Rails):
//
//	GET /health
//	GET /platform/contacts?page=&page_size=&filter[lead_stage]=&filter[tag]=&filter[email_domain]=
//	GET /platform/contacts/{id}   (agrega Contatos + Automação + Multicanalidade em paralelo)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	upstreamURL = getenv("UPSTREAM_URL", "http://localhost:9000")

	// Timeouts por domínio (resiliência por domínio)
	contactsTimeout = 1000 * time.Millisecond
	optionalTimeout = 300 * time.Millisecond

	client = &http.Client{
		Transport: &http.Transport{
			MaxIdleConns:        2000,
			MaxIdleConnsPerHost: 2000,
			IdleConnTimeout:     90 * time.Second,
		},
	}
)

// ---- contrato upstream ----

type upstreamContact struct {
	UUID      string            `json:"uuid"`
	Name      string            `json:"name"`
	Email     string            `json:"email"`
	JobTitle  string            `json:"job_title"`
	Tags      []string          `json:"tags"`
	LeadStage string            `json:"lead_stage"`
	CreatedAt int64             `json:"created_at"`
	CF        map[string]string `json:"cf"`
}

type upstreamList struct {
	Contacts []upstreamContact `json:"contacts"`
	Total    int               `json:"total"`
}

// ---- contrato público (OpenAPI) ----

type platformContact struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Email        string            `json:"email"`
	JobTitle     string            `json:"job_title"`
	Tags         []string          `json:"tags"`
	LeadStage    string            `json:"lead_stage"`
	CreatedAt    string            `json:"created_at"`
	CustomFields map[string]string `json:"custom_fields"`
}

func present(c upstreamContact) platformContact {
	return platformContact{
		ID:           c.UUID,
		Name:         c.Name,
		Email:        c.Email,
		JobTitle:     c.JobTitle,
		Tags:         c.Tags,
		LeadStage:    strings.ToLower(strings.ReplaceAll(c.LeadStage, " ", "_")),
		CreatedAt:    time.Unix(c.CreatedAt, 0).UTC().Format(time.RFC3339),
		CustomFields: c.CF,
	}
}

// ---- helpers ----

var errUpstream = errors.New("upstream error")

func fetchJSON(ctx context.Context, timeout time.Duration, path string, out any) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, upstreamURL+path, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if resp.StatusCode >= 300 {
		return fmt.Errorf("%w: status %d", errUpstream, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

var errNotFound = errors.New("not found")

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func atoiDefault(s string, d int) int {
	if v, err := strconv.Atoi(s); err == nil {
		return v
	}
	return d
}

// ---- handlers ----

func listContacts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page := max(atoiDefault(q.Get("page"), 1), 1)
	pageSize := min(max(atoiDefault(q.Get("page_size"), 25), 1), 100)
	fStage := q.Get("filter[lead_stage]")
	fTag := q.Get("filter[tag]")
	fDomain := q.Get("filter[email_domain]")

	var up upstreamList
	if err := fetchJSON(r.Context(), contactsTimeout, fmt.Sprintf("/contacts?page=%d&per_page=100", page), &up); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "contacts_unavailable"})
		return
	}

	data := make([]platformContact, 0, pageSize)
	for _, c := range up.Contacts {
		p := present(c)
		if fStage != "" && p.LeadStage != fStage {
			continue
		}
		if fTag != "" && !contains(p.Tags, fTag) {
			continue
		}
		if fDomain != "" && !strings.HasSuffix(p.Email, "@"+fDomain) {
			continue
		}
		data = append(data, p)
		if len(data) == pageSize {
			break
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"data": data,
		"meta": map[string]any{"page": page, "page_size": pageSize, "count": len(data)},
		"links": map[string]any{
			"next": fmt.Sprintf("/platform/contacts?page=%d&page_size=%d", page+1, pageSize),
		},
	})
}

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

func showContact(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	ctx := r.Context()

	var (
		wg      sync.WaitGroup
		contact upstreamContact
		flows   struct {
			Flows []map[string]any `json:"flows"`
		}
		channels struct {
			Channels []map[string]any `json:"channels"`
		}
		errC error
		errA error
		errM error
	)
	wg.Add(3)
	go func() { defer wg.Done(); errC = fetchJSON(ctx, contactsTimeout, "/contacts/"+id, &contact) }()
	go func() {
		defer wg.Done()
		errA = fetchJSON(ctx, optionalTimeout, "/automation/contacts/"+id+"/flows", &flows)
	}()
	go func() {
		defer wg.Done()
		errM = fetchJSON(ctx, optionalTimeout, "/multichannel/contacts/"+id+"/channels", &channels)
	}()
	wg.Wait()

	if errors.Is(errC, errNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if errC != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "contacts_unavailable"})
		return
	}

	degraded := []string{}
	var automation any
	if errA != nil {
		degraded = append(degraded, "automation")
	} else {
		automation = map[string]any{"flows": flows.Flows}
	}
	var chans any
	if errM != nil {
		degraded = append(degraded, "multichannel")
	} else {
		chans = channels.Channels
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"data": map[string]any{
			"contact":    present(contact),
			"automation": automation,
			"channels":   chans,
		},
		"meta": map[string]any{"degraded": degraded},
	})
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /platform/contacts", listContacts)
	mux.HandleFunc("GET /platform/contacts/{id}", showContact)

	port := getenv("PORT", "8080")
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("go-middleware on :%s upstream=%s", port, upstreamURL)
	log.Fatal(srv.ListenAndServe())
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
