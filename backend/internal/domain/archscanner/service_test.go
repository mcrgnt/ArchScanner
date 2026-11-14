package archscanner

import (
	"bytes"
	"context"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/mcrgnt/ArchScanner/backend/internal/domain/meshroom"
	"github.com/omcrgnt/scheduler"
)

func TestOpenMeshFile_states(t *testing.T) {
	st := &Store{root: t.TempDir()}
	svc := &Service{store: st}

	res, err := svc.OpenMeshFile(context.Background(), "p", "v")
	if err != nil {
		t.Fatal(err)
	}
	if !res.Missing {
		t.Fatalf("want missing, got %+v", res)
	}

	if err := st.EnsureVersion("p", "v"); err != nil {
		t.Fatal(err)
	}
	meshDir, _ := st.MeshDir("p", "v")
	path := filepath.Join(meshDir, "texturedMesh.obj")
	if err := os.WriteFile(path, []byte("o"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err = svc.OpenMeshFile(context.Background(), "p", "v")
	if err != nil {
		t.Fatal(err)
	}
	if res.Path != path || res.Missing || res.Accepted {
		t.Fatalf("got %+v", res)
	}
}

func TestSubmitMesh_andFile(t *testing.T) {
	st := &Store{root: t.TempDir()}
	storeMem := scheduler.NewMemoryStore()
	sched := &scheduler.Scheduler{}
	done := make(chan struct{}, 1)
	h := scheduler.Handle(meshroom.JobType, func(ctx context.Context, jobID string, p meshroom.JobPayload) error {
		defer func() { done <- struct{}{} }()
		if err := os.MkdirAll(p.OutputDir, 0o755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(p.OutputDir, "texturedMesh.obj"), []byte("mesh"), 0o644)
	})
	sched.Inject([]any{storeMem, scheduler.NewUUIDGenerator(), []scheduler.Handler{h}})
	ctx, cancel := context.WithCancel(context.Background())
	cleanup, err := sched.Start(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		cancel()
		_ = cleanup(context.Background())
	}()

	svc := &Service{store: st, sched: sched}
	jobID, err := svc.SubmitMesh(context.Background(), "toy", "v1", []IncomingFrame{
		{Filename: "a.jpg", Reader: bytes.NewBufferString("jpg")},
	}, MeshOpts{MaxImages: 1})
	if err != nil {
		t.Fatal(err)
	}
	if jobID == "" {
		t.Fatal("empty job id")
	}

	frames, err := st.FramesDir("toy", "v1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(frames, "a.jpg")); err != nil {
		t.Fatal(err)
	}

	<-done
	// allow status flip to done
	for i := 0; i < 50; i++ {
		res, err := svc.OpenMeshFile(context.Background(), "toy", "v1")
		if err != nil {
			t.Fatal(err)
		}
		if !res.Missing && !res.Accepted && res.Path != "" {
			return
		}
	}
	t.Fatal("mesh file not ready")
}

func TestReadMultipartFrames(t *testing.T) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fw, err := w.CreateFormFile("frames", "img_0001.jpg")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = fw.Write([]byte("jpeg-bytes"))
	_ = w.WriteField("max_images", "12")
	_ = w.WriteField("pipeline", "photogrammetryDraft")
	_ = w.WriteField("format", "obj")
	_ = w.Close()

	req := httptest.NewRequest("POST", "/mesh", &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())

	frames, opts, err := ReadMultipartFrames(req, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) != 1 || frames[0].Filename != "img_0001.jpg" {
		t.Fatalf("frames=%+v", frames)
	}
	if opts.MaxImages != 12 || opts.Pipeline != "photogrammetryDraft" || opts.Format != "obj" {
		t.Fatalf("opts=%+v", opts)
	}
}
