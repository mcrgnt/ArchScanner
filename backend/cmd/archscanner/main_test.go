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
