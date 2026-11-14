# ArchScanner

Wheel-arch / object capture: iOS client + Go backend (MinIO, mesh jobs via Meshroom).

## Layout

| Path | Role |
|------|------|
| `frontend/` | iOS app (XcodeGen, unsigned IPA CI) |
| `backend/` | Go service (REST, projects/versions, export, mesh jobs) |

Local scan dumps (`photos*`, `meshroom/`, `dist/`) stay gitignored / local-only.

## Frontend

```bash
cd frontend && xcodegen generate
```

CI: `.github/workflows/build-ipa.yml` (paths filter on `frontend/**`).

## Backend

```bash
cd backend && go run ./cmd/archscanner
```

Next: omcrgnt `app` / `srv-http` / `scheduler`, projects API, MinIO, `internal/meshroom`.
