// upstream-mock simula os serviços de domínio da plataforma
// (Contatos, Automação, Multicanalidade) com latência e falhas configuráveis.
//
// Variáveis de ambiente:
//
//	PORT              porta (default 9000)
//	BASE_LATENCY_MS   latência base de cada resposta (default 30)
//	JITTER_MS         variação aleatória somada à base (default 20)
//	SLOW_RATE         fração [0..1] das chamadas de Automação que ficam lentas (default 0)
//	SLOW_MS           latência das chamadas lentas (default 1000)
//	ERROR_RATE        fração [0..1] das chamadas de Multicanalidade que retornam 503 (default 0)
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"time"
)

const totalContacts = 5000

var (
	baseLatency = envInt("BASE_LATENCY_MS", 30)
	jitter      = envInt("JITTER_MS", 20)
	slowRate    = envFloat("SLOW_RATE", 0)
	slowMs      = envInt("SLOW_MS", 1000)
	errorRate   = envFloat("ERROR_RATE", 0)
)

var stages = []string{"Lead", "Qualified Lead", "Client"}
var tagPool = []string{"ecommerce", "saas", "webinar", "newsletter", "evento", "b2b", "b2c", "trial"}
var domains = []string{"gmail.com", "empresa.com.br", "exemplo.com", "outlook.com"}

type upstreamContact struct {
	UUID         string            `json:"uuid"`
	Name         string            `json:"name"`
	Email        string            `json:"email"`
	JobTitle     string            `json:"job_title"`
	Tags         []string          `json:"tags"`
	LeadStage    string            `json:"lead_stage"`
	CreatedAt    int64             `json:"created_at"`
	CF           map[string]string `json:"cf"`
	LegacyID     int               `json:"legacy_id"`
	InternalScor int               `json:"_internal_score"`
}

var contacts []upstreamContact
var contactsByID = map[string]upstreamContact{}

func buildDataset() {
	contacts = make([]upstreamContact, totalContacts)
	for i := 0; i < totalContacts; i++ {
		id := fmt.Sprintf("c-%06d", i+1)
		tags := []string{tagPool[i%len(tagPool)], tagPool[(i*3+1)%len(tagPool)]}
		c := upstreamContact{
			UUID:      id,
			Name:      fmt.Sprintf("Contato %d", i+1),
			Email:     fmt.Sprintf("contato%d@%s", i+1, domains[i%len(domains)]),
			JobTitle:  []string{"Analista", "Gerente", "Diretor", "Coordenador"}[i%4],
			Tags:      tags,
			LeadStage: stages[i%len(stages)],
			CreatedAt: 1700000000 + int64(i)*3600,
			CF: map[string]string{
				"cf_segmento": []string{"varejo", "industria", "servicos"}[i%3],
				"cf_cidade":   []string{"Joinville", "Florianopolis", "Sao Paulo", "Curitiba"}[i%4],
				"cf_origem":   []string{"organico", "pago", "indicacao"}[i%3],
			},
			LegacyID:     900000 + i,
			InternalScor: i % 100,
		}
		contacts[i] = c
		contactsByID[id] = c
	}
}

func sleep(extraSlow bool) {
	d := baseLatency
	if jitter > 0 {
		d += rand.IntN(jitter + 1)
	}
	if extraSlow {
		d = slowMs
	}
	time.Sleep(time.Duration(d) * time.Millisecond)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	buildDataset()
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})

	// Contatos: listagem paginada (o upstream não filtra; o middleware filtra)
	mux.HandleFunc("GET /contacts", func(w http.ResponseWriter, r *http.Request) {
		page := atoiDefault(r.URL.Query().Get("page"), 1)
		perPage := atoiDefault(r.URL.Query().Get("per_page"), 100)
		if perPage > 200 {
			perPage = 200
		}
		start := (page - 1) * perPage
		if start < 0 || start >= totalContacts {
			sleep(false)
			writeJSON(w, 200, map[string]any{"contacts": []upstreamContact{}, "total": totalContacts})
			return
		}
		end := min(start+perPage, totalContacts)
		sleep(false)
		writeJSON(w, 200, map[string]any{"contacts": contacts[start:end], "total": totalContacts})
	})

	mux.HandleFunc("GET /contacts/{id}", func(w http.ResponseWriter, r *http.Request) {
		c, ok := contactsByID[r.PathValue("id")]
		sleep(false)
		if !ok {
			writeJSON(w, 404, map[string]string{"error": "not_found"})
			return
		}
		writeJSON(w, 200, c)
	})

	// Automação: pode ficar lenta (testa timeout por domínio)
	mux.HandleFunc("GET /automation/contacts/{id}/flows", func(w http.ResponseWriter, r *http.Request) {
		sleep(slowRate > 0 && rand.Float64() < slowRate)
		n := len(r.PathValue("id"))
		writeJSON(w, 200, map[string]any{"flows": []map[string]any{
			{"id": "flow-1", "name": "Nutrição de leads", "status": "active", "step": n % 5},
			{"id": "flow-2", "name": "Boas-vindas", "status": "finished", "step": 3},
		}})
	})

	// Multicanalidade: pode retornar erro (testa degradação)
	mux.HandleFunc("GET /multichannel/contacts/{id}/channels", func(w http.ResponseWriter, r *http.Request) {
		sleep(false)
		if errorRate > 0 && rand.Float64() < errorRate {
			writeJSON(w, 503, map[string]string{"error": "unavailable"})
			return
		}
		writeJSON(w, 200, map[string]any{"channels": []map[string]any{
			{"type": "email", "opt_in": true},
			{"type": "whatsapp", "opt_in": false},
			{"type": "sms", "opt_in": true},
		}})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "9000"
	}
	log.Printf("upstream-mock on :%s base=%dms jitter=%dms slow_rate=%.2f error_rate=%.2f", port, baseLatency, jitter, slowRate, errorRate)
	srv := &http.Server{Addr: ":" + port, Handler: mux}
	log.Fatal(srv.ListenAndServe())
}

func envInt(k string, d int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return v
	}
	return d
}

func envFloat(k string, d float64) float64 {
	if v, err := strconv.ParseFloat(os.Getenv(k), 64); err == nil {
		return v
	}
	return d
}

func atoiDefault(s string, d int) int {
	if v, err := strconv.Atoi(s); err == nil {
		return v
	}
	return d
}
