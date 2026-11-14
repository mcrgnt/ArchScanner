package archscanner

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/omcrgnt/app"
)

const defaultDataRoot = "/opt/root/ArchScanner/data"

// DataRoot is the filesystem root for projects/versions (opaque to clients).
type DataRoot string

func (DataRoot) Usage() string { return "Root directory for project/version data" }

func (DataRoot) Validate() error { return nil }

// Spec materializes [Store].
type Spec struct {
	Root DataRoot
}

// Store is a local FS layout for projects and versions.
type Store struct {
	root string
}

type versionMeta struct {
	LastJobID string `json:"last_job_id,omitempty"`
}

// IncomingFrame is one uploaded file for a version.
type IncomingFrame struct {
	Filename string
	Reader   io.Reader
}

func (*Store) BuildConfig() (app.Materializer, error) {
	return &Spec{}, nil
}

func (s Spec) Build() (any, error) {
	root := strings.TrimSpace(string(s.Root))
	if root == "" {
		root = defaultDataRoot
	}
	root = filepath.Clean(root)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("data root %q: %w", root, err)
	}
	return &Store{root: root}, nil
}

func sanitizeID(id string) (string, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return "", fmt.Errorf("id is empty")
	}
	if strings.Contains(id, "..") || strings.ContainsAny(id, `/\`) {
		return "", fmt.Errorf("invalid id %q", id)
	}
	return id, nil
}

func (s *Store) versionDir(projectID, versionID string) (string, error) {
	pid, err := sanitizeID(projectID)
	if err != nil {
		return "", fmt.Errorf("project_id: %w", err)
	}
	vid, err := sanitizeID(versionID)
	if err != nil {
		return "", fmt.Errorf("version_id: %w", err)
	}
	return filepath.Join(s.root, "projects", pid, "versions", vid), nil
}

func (s *Store) EnsureVersion(projectID, versionID string) error {
	dir, err := s.versionDir(projectID, versionID)
	if err != nil {
		return err
	}
	for _, sub := range []string{"frames", "mesh"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o755); err != nil {
			return err
		}
	}
	metaPath := filepath.Join(dir, "meta.json")
	if _, err := os.Stat(metaPath); os.IsNotExist(err) {
		return s.writeMeta(dir, versionMeta{})
	}
	return nil
}

func (s *Store) FramesDir(projectID, versionID string) (string, error) {
	dir, err := s.versionDir(projectID, versionID)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "frames"), nil
}

func (s *Store) MeshDir(projectID, versionID string) (string, error) {
	dir, err := s.versionDir(projectID, versionID)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "mesh"), nil
}

// ReplaceFrames clears frames/ and writes uploaded files. Also clears mesh/.
func (s *Store) ReplaceFrames(projectID, versionID string, frames []IncomingFrame) error {
	if err := s.EnsureVersion(projectID, versionID); err != nil {
		return err
	}
	framesDir, err := s.FramesDir(projectID, versionID)
	if err != nil {
		return err
	}
	meshDir, err := s.MeshDir(projectID, versionID)
	if err != nil {
		return err
	}
	if err := resetDir(framesDir); err != nil {
		return err
	}
	if err := resetDir(meshDir); err != nil {
		return err
	}
	if len(frames) == 0 {
		return fmt.Errorf("no frames uploaded")
	}
	for _, f := range frames {
		name := filepath.Base(strings.TrimSpace(f.Filename))
		if name == "" || name == "." || name == ".." {
			return fmt.Errorf("invalid frame filename %q", f.Filename)
		}
		dst := filepath.Join(framesDir, name)
		out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(out, f.Reader)
		closeErr := out.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func (s *Store) SetMeshJob(projectID, versionID, jobID string) error {
	dir, err := s.versionDir(projectID, versionID)
	if err != nil {
		return err
	}
	return s.writeMeta(dir, versionMeta{LastJobID: jobID})
}

func (s *Store) LastJobID(projectID, versionID string) (string, error) {
	dir, err := s.versionDir(projectID, versionID)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(dir); err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	m, err := s.readMeta(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return m.LastJobID, nil
}

// MeshFile returns the primary mesh artifact path under mesh/, or "" if none.
func (s *Store) MeshFile(projectID, versionID string) (string, error) {
	meshDir, err := s.MeshDir(projectID, versionID)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(meshDir); err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	var found string
	_ = filepath.WalkDir(meshDir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		switch strings.ToLower(filepath.Ext(d.Name())) {
		case ".obj", ".gltf", ".glb", ".ply", ".abc":
			found = path
			return filepath.SkipAll
		}
		return nil
	})
	return found, nil
}

func (s *Store) ListProjects() ([]string, error) {
	root := filepath.Join(s.root, "projects")
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, e.Name())
		}
	}
	return out, nil
}

func (s *Store) writeMeta(versionDir string, m versionMeta) error {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(versionDir, "meta.json"), b, 0o644)
}

func (s *Store) readMeta(versionDir string) (versionMeta, error) {
	b, err := os.ReadFile(filepath.Join(versionDir, "meta.json"))
	if err != nil {
		return versionMeta{}, err
	}
	var m versionMeta
	if err := json.Unmarshal(b, &m); err != nil {
		return versionMeta{}, err
	}
	return m, nil
}

func resetDir(dir string) error {
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	return os.MkdirAll(dir, 0o755)
}
