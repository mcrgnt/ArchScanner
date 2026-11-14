package archscanner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"

	"github.com/mcrgnt/ArchScanner/backend/internal/domain/meshroom"
	"github.com/omcrgnt/scheduler"
)

// Service is the domain entry for projects/versions and mesh jobs.
type Service struct {
	store *Store
	sched *scheduler.Scheduler
}

// MeshOpts are optional Meshroom overrides from the upload form.
type MeshOpts struct {
	MaxImages int
	Pipeline  string
	// Format is the deliverable for mesh/file (obj|usdz). Default usdz.
	Format string
}

// MeshFileResult is the outcome of OpenMeshFile.
type MeshFileResult struct {
	Path        string
	ContentType string
	// Accepted means job is still queued/running (HTTP 202).
	Accepted bool
	// Missing means no mesh and no active job (HTTP 404).
	Missing bool
}

func (*Service) NewResource() (any, error) { return &Service{}, nil }

func (s *Service) Deps() []any {
	return []any{(*Store)(nil), (*scheduler.Scheduler)(nil)}
}

func (s *Service) Inject(args []any) {
	for _, arg := range args {
		switch v := arg.(type) {
		case *Store:
			s.store = v
		case *scheduler.Scheduler:
			s.sched = v
		}
	}
}

// SubmitMesh stores uploaded frames for the version and enqueues a meshroom job.
func (s *Service) SubmitMesh(ctx context.Context, projectID, versionID string, frames []IncomingFrame, opts MeshOpts) (string, error) {
	if s.store == nil || s.sched == nil {
		return "", fmt.Errorf("archscanner: not wired")
	}
	if err := s.store.ReplaceFrames(projectID, versionID, frames); err != nil {
		return "", err
	}
	framesDir, err := s.store.FramesDir(projectID, versionID)
	if err != nil {
		return "", err
	}
	meshDir, err := s.store.MeshDir(projectID, versionID)
	if err != nil {
		return "", err
	}

	format := meshroom.NormalizeFormat(opts.Format)
	jobID, err := scheduler.Submit(s.sched, ctx, meshroom.JobType, meshroom.JobPayload{
		ProjectID: projectID,
		VersionID: versionID,
		InputDir:  framesDir,
		OutputDir: meshDir,
		Format:    format,
		MaxImages: opts.MaxImages,
		Pipeline:  opts.Pipeline,
	})
	if err != nil {
		return "", err
	}
	if err := s.store.SetMeshJob(projectID, versionID, jobID, format); err != nil {
		return "", err
	}
	return jobID, nil
}

// OpenMeshFile resolves the downloadable mesh for a version.
func (s *Service) OpenMeshFile(ctx context.Context, projectID, versionID string) (MeshFileResult, error) {
	if s.store == nil {
		return MeshFileResult{}, fmt.Errorf("archscanner: not wired")
	}
	path, err := s.store.MeshFile(projectID, versionID)
	if err != nil {
		return MeshFileResult{}, err
	}
	if path != "" {
		if _, err := os.Stat(path); err == nil {
			return MeshFileResult{
				Path:        path,
				ContentType: contentTypeFor(path),
			}, nil
		}
	}

	jobID, err := s.store.LastJobID(projectID, versionID)
	if err != nil {
		return MeshFileResult{}, err
	}
	if jobID == "" || s.sched == nil {
		return MeshFileResult{Missing: true}, nil
	}
	job, err := s.sched.Status(ctx, jobID)
	if err != nil {
		return MeshFileResult{Missing: true}, nil
	}
	switch job.Status {
	case scheduler.StatusQueued, scheduler.StatusRunning:
		return MeshFileResult{Accepted: true}, nil
	default:
		return MeshFileResult{Missing: true}, nil
	}
}

// JobStatus returns the current scheduler snapshot for jobID.
func (s *Service) JobStatus(ctx context.Context, jobID string) (scheduler.Job, error) {
	if s.sched == nil {
		return scheduler.Job{}, fmt.Errorf("archscanner: not wired")
	}
	return s.sched.Status(ctx, jobID)
}

// ListProjects returns project ids present in the store.
func (s *Service) ListProjects() ([]string, error) {
	if s.store == nil {
		return nil, fmt.Errorf("archscanner: not wired")
	}
	return s.store.ListProjects()
}

func contentTypeFor(path string) string {
	ext := filepath.Ext(path)
	if ct := mime.TypeByExtension(ext); ct != "" {
		return ct
	}
	switch ext {
	case ".usdz":
		return "model/vnd.usdz+zip"
	case ".obj":
		return "model/obj"
	case ".gltf":
		return "model/gltf+json"
	case ".glb":
		return "model/gltf-binary"
	default:
		return "application/octet-stream"
	}
}

// ParseMaxImages parses an optional form field.
func ParseMaxImages(s string) (int, error) {
	if s == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// ReadMultipartFrames extracts all "frames" file parts from a multipart request.
func ReadMultipartFrames(r *http.Request, maxMemory int64) ([]IncomingFrame, MeshOpts, error) {
	if err := r.ParseMultipartForm(maxMemory); err != nil {
		return nil, MeshOpts{}, err
	}
	opts := MeshOpts{
		Pipeline: r.FormValue("pipeline"),
		Format:   r.FormValue("format"),
	}
	if v := r.FormValue("max_images"); v != "" {
		n, err := ParseMaxImages(v)
		if err != nil {
			return nil, MeshOpts{}, fmt.Errorf("max_images: %w", err)
		}
		opts.MaxImages = n
	}

	if r.MultipartForm == nil {
		return nil, opts, errors.New("expected multipart form")
	}
	headers := r.MultipartForm.File["frames"]
	if len(headers) == 0 {
		headers = r.MultipartForm.File["frame"]
	}
	if len(headers) == 0 {
		return nil, opts, errors.New("missing frames")
	}

	out := make([]IncomingFrame, 0, len(headers))
	for _, h := range headers {
		f, err := h.Open()
		if err != nil {
			return nil, opts, err
		}
		b, err := io.ReadAll(f)
		_ = f.Close()
		if err != nil {
			return nil, opts, err
		}
		out = append(out, IncomingFrame{
			Filename: h.Filename,
			Reader:   bytes.NewReader(b),
		})
	}
	return out, opts, nil
}
