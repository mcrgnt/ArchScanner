package http

import (
	"encoding/json"
	nethttp "net/http"

	"github.com/go-chi/chi/v5"
	"github.com/mcrgnt/ArchScanner/backend/internal/domain/archscanner"
	"github.com/mcrgnt/ArchScanner/backend/internal/domain/meshroom"
)

type Router struct {
	mux *chi.Mux
	svc *archscanner.Service
}

func (r *Router) NewResource() (any, error) {
	return &Router{mux: chi.NewRouter()}, nil
}

func (r *Router) Deps() []any {
	return []any{(*archscanner.Service)(nil)}
}

func (r *Router) Inject(args []any) {
	for _, arg := range args {
		switch v := arg.(type) {
		case *archscanner.Service:
			r.svc = v
		}
	}
	r.registerRoutes()
}

func (r *Router) ServeHTTP(w nethttp.ResponseWriter, req *nethttp.Request) {
	r.mux.ServeHTTP(w, req)
}

func (r *Router) registerRoutes() {
	r.mux.Route("/api/v1", func(api chi.Router) {
		api.Get("/projects", r.listProjects)
		api.Post("/projects/{projectID}/versions/{versionID}/mesh", r.enqueueMesh)
		api.Get("/jobs/{jobID}", r.jobStatus)
	})
}

func (r *Router) listProjects(w nethttp.ResponseWriter, _ *nethttp.Request) {
	writeJSON(w, nethttp.StatusOK, []any{})
}

func (r *Router) enqueueMesh(w nethttp.ResponseWriter, req *nethttp.Request) {
	projectID := chi.URLParam(req, "projectID")
	versionID := chi.URLParam(req, "versionID")
	var body struct {
		Prefix string `json:"prefix"`
	}
	if req.Body != nil {
		_ = json.NewDecoder(req.Body).Decode(&body)
	}
	id, err := r.svc.EnqueueMesh(req.Context(), meshroom.JobPayload{
		ProjectID: projectID,
		VersionID: versionID,
		Prefix:    body.Prefix,
	})
	if err != nil {
		writeJSON(w, nethttp.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, nethttp.StatusAccepted, map[string]string{"job_id": id})
}

func (r *Router) jobStatus(w nethttp.ResponseWriter, req *nethttp.Request) {
	jobID := chi.URLParam(req, "jobID")
	job, err := r.svc.JobStatus(req.Context(), jobID)
	if err != nil {
		writeJSON(w, nethttp.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, nethttp.StatusOK, map[string]any{
		"id":     job.ID,
		"type":   job.Type,
		"status": job.Status,
		"error":  job.Err,
	})
}

func writeJSON(w nethttp.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
