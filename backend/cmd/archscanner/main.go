package main

import (
	"log"

	_ "github.com/omcrgnt/meta/core/use"
	_ "github.com/omcrgnt/scheduler/use"

	httpapi "github.com/mcrgnt/ArchScanner/backend/internal/api/http"
	"github.com/mcrgnt/ArchScanner/backend/internal/domain/archscanner"
	"github.com/mcrgnt/ArchScanner/backend/internal/domain/meshroom"
	"github.com/omcrgnt/app"
	"github.com/omcrgnt/obs"
	ophttp "github.com/omcrgnt/ops/transport/http"
	"github.com/omcrgnt/res"
	"github.com/omcrgnt/res/unique"
	srvhttp "github.com/omcrgnt/srv-http"
)

const envPrefix = "ARCHSCANNER"

type _appResources struct {
	ServerHTTPOps *ophttp.Server                   `ecfg:"OPS_HTTP"`
	ServerHTTP    *srvhttp.Server[*httpapi.Router] `ecfg:"SERVER_HTTP"`
	Router        *httpapi.Router
	Store         *archscanner.Store `ecfg:"DATA"`
	Service       *archscanner.Service
	Meshroom      *meshroom.Runner `ecfg:"MESHROOM"`
}

var appResources _appResources

func main() {
	pipeline := app.Pipeline{
		Registry:   unique.Global(),
		EnvPrefix:  envPrefix,
		Transforms: []res.TransformFunc{obs.ApplyTransform},
	}
	if err := app.Run(&appResources, pipeline); err != nil {
		log.Fatal(err)
	}
}
