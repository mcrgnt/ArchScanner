package archscanner

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestStore_ReplaceFramesAndMeshFile(t *testing.T) {
	root := t.TempDir()
	st := &Store{root: root}

	err := st.ReplaceFrames("proj1", "v1", []IncomingFrame{
		{Filename: "img_0001.jpg", Reader: bytes.NewBufferString("jpeg")},
		{Filename: "img_0001.json", Reader: bytes.NewBufferString(`{}`)},
	})
	if err != nil {
		t.Fatal(err)
	}

	frames, err := st.FramesDir("proj1", "v1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(frames, "img_0001.jpg")); err != nil {
		t.Fatal(err)
	}

	meshDir, err := st.MeshDir("proj1", "v1")
	if err != nil {
		t.Fatal(err)
	}
	obj := filepath.Join(meshDir, "texturedMesh.obj")
	usdz := filepath.Join(meshDir, "texturedMesh.usdz")
	if err := os.WriteFile(obj, []byte("o"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(usdz, []byte("z"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMeshJob("proj1", "v1", "job-1", "usdz"); err != nil {
		t.Fatal(err)
	}
	got, err := st.MeshFile("proj1", "v1")
	if err != nil {
		t.Fatal(err)
	}
	if got != usdz {
		t.Fatalf("got %q want %q", got, usdz)
	}
	jid, err := st.LastJobID("proj1", "v1")
	if err != nil {
		t.Fatal(err)
	}
	if jid != "job-1" {
		t.Fatalf("job=%q", jid)
	}
}

func TestStore_RejectsPathTraversal(t *testing.T) {
	st := &Store{root: t.TempDir()}
	if err := st.EnsureVersion("../x", "v1"); err == nil {
		t.Fatal("expected error")
	}
}

func TestSpecBuild_defaultRoot(t *testing.T) {
	built, err := (Spec{Root: DataRoot(t.TempDir())}).Build()
	if err != nil {
		t.Fatal(err)
	}
	if built.(*Store).root == "" {
		t.Fatal("empty root")
	}
}
