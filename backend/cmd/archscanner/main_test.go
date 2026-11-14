package main

import (
	"reflect"
	"testing"

	"github.com/mcrgnt/ArchScanner/backend/internal/domain/archscanner"
	"github.com/omcrgnt/app"
	"github.com/omcrgnt/res"
	"github.com/omcrgnt/res/unique"
	"github.com/omcrgnt/scheduler"
)

func TestAppResources_Bootstrap(t *testing.T) {
	t.Setenv("ARCHSCANNER_OPS_HTTP_HOST", "127.0.0.1")
	t.Setenv("ARCHSCANNER_OPS_HTTP_LABEL", "archscanner_ops")
	t.Setenv("ARCHSCANNER_OPS_HTTP_PORT", "18781")
	t.Setenv("ARCHSCANNER_SERVER_HTTP_HOST", "127.0.0.1")
	t.Setenv("ARCHSCANNER_SERVER_HTTP_LABEL", "archscanner")
	t.Setenv("ARCHSCANNER_SERVER_HTTP_PORT", "18780")
	t.Setenv("ARCHSCANNER_DATA_ROOT", t.TempDir())
	t.Setenv("ARCHSCANNER_MESHROOM_BIN", "/opt/Meshroom-2025.1.0/meshroom_batch")
	t.Setenv("ARCHSCANNER_MESHROOM_BLENDER", "/home/xxx/.local/bin/blender")
	t.Setenv("ARCHSCANNER_MESHROOM_WORK_ROOT", t.TempDir())
	t.Setenv("ARCHSCANNER_MESHROOM_PIPELINE", "photogrammetryDraft")
	t.Setenv("ARCHSCANNER_MESHROOM_MAX_IMAGES", "24")

	reg := unique.Global()
	var ar _appResources

	if _, err := app.Bootstrap(&ar, app.Pipeline{
		Registry:  reg,
		EnvPrefix: envPrefix,
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := reg.GetOneByType(reflect.TypeOf((*archscanner.Service)(nil))); err != nil {
		t.Fatalf("service: %v", err)
	}
	if _, err := reg.GetOneByType(reflect.TypeOf((*scheduler.Scheduler)(nil))); err != nil {
		t.Fatalf("scheduler: %v", err)
	}

	n := 0
	reg.WalkEntries(func(_ res.Entry) bool {
		n++
		return true
	})
	if n == 0 {
		t.Fatal("expected resources")
	}
}
