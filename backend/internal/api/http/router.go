package http

import (
	"encoding/json"
	"io"
	nethttp "net/http"
	"os"
	"path/filepath"

	"github.com/go-chi/chi/v5"
	"github.com/mcrgnt/ArchScanner/backend/internal/domain/archscanner"
)

const multipartMaxMemory = 64 << 20 // 64 MiB in memory; rest spills to disk

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
		api.Get("/projects/{projectID}/versions/{versionID}/mesh/file", r.meshFile)
		api.Get("/jobs/{jobID}", r.jobStatus)
	})
}

func (r *Router) listProjects(w nethttp.ResponseWriter, _ *nethttp.Request) {
	ids, err := r.svc.ListProjects()
	if err != nil {
		writeJSON(w, nethttp.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if ids == nil {
		ids = []string{}
	}
	writeJSON(w, nethttp.StatusOK, ids)
}

func (r *Router) enqueueMesh(w nethttp.ResponseWriter, req *nethttp.Request) {
	projectID := chi.URLParam(req, "projectID")
	versionID := chi.URLParam(req, "versionID")

	frames, opts, err := archscanner.ReadMultipartFrames(req, multipartMaxMemory)
	if err != nil {
		writeJSON(w, nethttp.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	id, err := r.svc.SubmitMesh(req.Context(), projectID, versionID, frames, opts)
	if err != nil {
		writeJSON(w, nethttp.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, nethttp.StatusAccepted, map[string]string{"job_id": id})
}

func (r *Router) meshFile(w nethttp.ResponseWriter, req *nethttp.Request) {
	projectID := chi.URLParam(req, "projectID")
	versionID := chi.URLParam(req, "versionID")

	res, err := r.svc.OpenMeshFile(req.Context(), projectID, versionID)
	if err != nil {
		writeJSON(w, nethttp.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if res.Accepted {
		writeJSON(w, nethttp.StatusAccepted, map[string]string{"status": "processing"})
		return
	}
	if res.Missing || res.Path == "" {
		writeJSON(w, nethttp.StatusNotFound, map[string]string{"error": "mesh not ready"})
		return
	}

	f, err := os.Open(res.Path)
	if err != nil {
		writeJSON(w, nethttp.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", res.ContentType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+filepath.Base(res.Path)+`"`)
	w.WriteHeader(nethttp.StatusOK)
	_, _ = io.Copy(w, f)
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
