package archscanner

import (
	"context"

	"github.com/mcrgnt/ArchScanner/backend/internal/domain/meshroom"
	"github.com/omcrgnt/scheduler"
)

// Service is the domain entry for projects/versions and mesh job submission.
// Persistence (DB/MinIO) lands here next; scheduler wiring is already live.
type Service struct {
	sched *scheduler.Scheduler
}

func (*Service) NewResource() (any, error) { return &Service{}, nil }

func (s *Service) Deps() []any {
	return []any{(*scheduler.Scheduler)(nil)}
}

func (s *Service) Inject(args []any) {
	for _, arg := range args {
		switch v := arg.(type) {
		case *scheduler.Scheduler:
			s.sched = v
		}
	}
}

// EnqueueMesh submits a meshroom job (payload = instructions, not media bytes).
func (s *Service) EnqueueMesh(ctx context.Context, p meshroom.JobPayload) (string, error) {
	return scheduler.Submit(s.sched, ctx, meshroom.JobType, p)
}

// JobStatus returns the current scheduler snapshot for jobID.
func (s *Service) JobStatus(ctx context.Context, jobID string) (scheduler.Job, error) {
	return s.sched.Status(ctx, jobID)
}
