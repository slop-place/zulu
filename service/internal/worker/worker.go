package worker

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/notify"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/service"
	"github.com/bwees/zulu/service/internal/zulip"
)

var (
	// errNoDevices ends a worker: without a device token there is nothing to
	// notify, and holding the queue would only keep Zulip's own notifications
	// suppressed.
	errNoDevices = errors.New("worker: user has no devices")
	// errUndeliverable ends a session and parks the worker, handing notification
	// duty back to Zulip.
	errUndeliverable = errors.New("worker: pushes are not reaching any device")
)

// Dispatcher is the push fan-out as the worker needs it.
type Dispatcher interface {
	Dispatch(ctx context.Context, user domain.User, event zulip.MessageEvent, decision notify.Decision) (service.DispatchResult, error)
}

// Worker runs one user's Zulip event queue.
type Worker struct {
	user       domain.User
	users      *repository.UserRepository
	queues     *repository.QueueRepository
	devices    *repository.DeviceRepository
	zulip      *zulip.Client
	dispatcher Dispatcher
	log        *slog.Logger

	// deliveryGrace is how long every push may keep failing before the worker
	// parks.
	deliveryGrace time.Duration

	mu     sync.Mutex
	health domain.WorkerHealth
}

func newWorker(user domain.User, deps Deps, log *slog.Logger) *Worker {
	return &Worker{
		user:          user,
		users:         deps.Users,
		queues:        deps.Queues,
		devices:       deps.Devices,
		zulip:         deps.Zulip,
		dispatcher:    deps.Dispatcher,
		deliveryGrace: deps.DeliveryGrace,
		log:           log.With("user_id", user.ID, "realm", user.RealmURL),
		health:        domain.WorkerHealth{Running: true},
	}
}

func (w *Worker) Health() domain.WorkerHealth {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.health
}

func (w *Worker) updateHealth(mutate func(*domain.WorkerHealth)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	mutate(&w.health)
}

// Run polls until the context ends or the user stops being notifiable.
func (w *Worker) Run(ctx context.Context) {
	transient := NewBackoff(100*time.Millisecond, 10*time.Second)
	unexpected := NewBackoff(time.Second, 60*time.Second)

	defer w.updateHealth(func(health *domain.WorkerHealth) {
		health.Running = false
		health.Connected = false
	})

	for ctx.Err() == nil {
		err := w.session(ctx)
		switch {
		case err == nil, errors.Is(err, context.Canceled):
			return

		case errors.Is(err, errNoDevices):
			w.log.Info("stopping worker: no devices left to notify")
			return

		case zulip.IsUnauthorized(err):
			// One API key per account: the user regenerated it somewhere and
			// every stored copy died at once. Only a fresh registration fixes it.
			w.log.Warn("zulip rejected the stored api key; stopping worker")
			w.recordStatus(ctx, domain.UserAuthFailed, "Zulip rejected the stored API key. Sign in again in Zulu.")
			w.dropQueue(ctx)
			return

		case zulip.IsBadEventQueueID(err):
			// A collected queue is normal, not a fault: re-register at once.
			w.log.Info("event queue expired; re-registering")
			w.forgetQueue(ctx)
			transient.Reset()

		case errors.Is(err, errUndeliverable):
			w.park(ctx)
			if sleepErr := sleep(ctx, w.deliveryGrace); sleepErr != nil {
				return
			}
			w.updateHealth(func(health *domain.WorkerHealth) { health.Parked = false })

		case zulip.IsRateLimited(err):
			wait, ok := zulip.RetryAfter(err)
			if !ok {
				wait = transient.Next()
			}
			w.noteError(err)
			if sleepErr := sleep(ctx, wait); sleepErr != nil {
				return
			}

		default:
			w.noteError(err)
			wait := transient.Next()
			if !isTransient(err) {
				w.log.Error("unexpected polling error", "error", err)
				wait = unexpected.Next()
			}
			if sleepErr := sleep(ctx, wait); sleepErr != nil {
				return
			}
		}
	}
}

// session registers or resumes a queue and polls it until something goes wrong.
func (w *Worker) session(ctx context.Context) error {
	devices, err := w.devices.ListByUser(ctx, w.user.ID)
	if err != nil {
		return err
	}
	if len(devices) == 0 {
		w.dropQueue(ctx)
		return errNoDevices
	}

	creds, err := w.users.Credentials(ctx, w.user.ID)
	if err != nil {
		return err
	}

	queue, timeout, err := w.resumeOrRegister(ctx, creds)
	if err != nil {
		return err
	}

	w.updateHealth(func(health *domain.WorkerHealth) {
		health.Connected = true
		health.LastError = ""
	})
	defer w.updateHealth(func(health *domain.WorkerHealth) { health.Connected = false })

	// The breaker measures a run of failures, not silence: a user whose channels
	// are quiet must not be parked for having nothing to deliver.
	var failingSince time.Time
	for {
		events, err := w.poll(ctx, creds, queue, timeout)
		if err != nil {
			return err
		}

		pushes, err := w.handleEvents(ctx, &queue, events)
		if err != nil {
			return err
		}
		switch {
		case pushes.delivered > 0:
			failingSince = time.Time{}
		case pushes.attempted > 0 && failingSince.IsZero():
			failingSince = time.Now()
		}
		if !failingSince.IsZero() && time.Since(failingSince) > w.deliveryGrace {
			return errUndeliverable
		}
	}
}

// pushCounts is what one batch of events produced.
type pushCounts struct {
	attempted int
	delivered int
}

func (w *Worker) poll(ctx context.Context, creds domain.Credentials, queue domain.QueueState, timeout time.Duration) ([]zulip.Event, error) {
	// A poll that outlives the server's own long-poll window has a dead
	// connection even if the socket still looks open. The margin covers the
	// server's heartbeat jitter and the round trip.
	pollCtx, cancel := context.WithTimeout(ctx, timeout+15*time.Second)
	defer cancel()

	events, err := w.zulip.Events(pollCtx, creds, queue.QueueID, queue.LastEventID)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	return events, nil
}

// handleEvents applies a batch and persists the cursor.
func (w *Worker) handleEvents(ctx context.Context, queue *domain.QueueState, events []zulip.Event) (pushCounts, error) {
	stateChanged := false
	pushes := pushCounts{}

	for _, event := range events {
		// Delivery is at-least-once: a lost acknowledgement replays events that
		// were already applied.
		if event.ID <= queue.LastEventID {
			continue
		}

		switch event.Type {
		case zulip.EventMessage:
			result, err := w.handleMessage(ctx, event, queue.State)
			if err != nil {
				return pushes, err
			}
			pushes.attempted += result.Attempted
			pushes.delivered += result.Delivered

		case zulip.EventHeartbeat:
			// Nothing to do; its arrival is the connection-alive signal.

		default:
			changed, err := zulip.ApplyEvent(queue.State, event)
			if err != nil {
				// Carrying on with a half-applied settings mirror would notify by
				// the wrong rules, so give up the queue and take a fresh snapshot.
				return pushes, fmt.Errorf("apply %s event: %w", event.Type, err)
			}
			stateChanged = stateChanged || changed
		}

		queue.LastEventID = event.ID
		w.updateHealth(func(health *domain.WorkerHealth) { health.LastEventAt = time.Now() })
	}

	if len(events) == 0 {
		return pushes, nil
	}
	if stateChanged {
		return pushes, w.queues.Save(ctx, w.user.ID, *queue)
	}
	return pushes, w.queues.Advance(ctx, w.user.ID, queue.LastEventID)
}

func (w *Worker) handleMessage(ctx context.Context, event zulip.Event, state *notify.State) (service.DispatchResult, error) {
	message, err := zulip.DecodeMessageEvent(event)
	if err != nil {
		return service.DispatchResult{}, err
	}

	decision := notify.Decide(service.DecisionInput(w.user, message, state))
	if !decision.Notify {
		w.log.Debug("message not notifiable",
			"message_id", message.Message.ID, "reason", decision.Reason)
		return service.DispatchResult{}, nil
	}

	result, err := w.dispatcher.Dispatch(ctx, w.user, message, decision)
	if err != nil {
		return service.DispatchResult{}, err
	}
	w.log.Info("notification dispatched",
		"message_id", message.Message.ID,
		"trigger", decision.Trigger,
		"attempted", result.Attempted,
		"delivered", result.Delivered)
	return result, nil
}

// resumeOrRegister reuses the stored queue when there is one, so a restart does
// not cost a fresh snapshot, and registers a new one otherwise.
func (w *Worker) resumeOrRegister(ctx context.Context, creds domain.Credentials) (domain.QueueState, time.Duration, error) {
	stored, err := w.queues.Load(ctx, w.user.ID)
	if err == nil {
		return stored, zulip.DefaultLongpollTimeout, nil
	}
	if !errors.Is(err, repository.ErrNotFound) {
		return domain.QueueState{}, 0, err
	}

	response, err := w.zulip.Register(ctx, creds)
	if err != nil {
		return domain.QueueState{}, 0, err
	}
	queue := domain.QueueState{
		QueueID:     response.QueueID,
		LastEventID: response.LastEventID,
		State:       zulip.BuildState(response),
	}
	if err := w.queues.Save(ctx, w.user.ID, queue); err != nil {
		return domain.QueueState{}, 0, err
	}
	w.log.Info("registered event queue",
		"queue_id", queue.QueueID,
		"feature_level", response.ZulipFeatureLevel,
		"channels", len(response.Subscriptions))
	return queue, response.LongpollTimeout(), nil
}

// park gives the queue back after pushes have stopped landing, so that Zulip
// resumes its own push and email for this user within its ten-minute offline
// window.
func (w *Worker) park(ctx context.Context) {
	w.log.Warn("parking worker: no push has reached a device within the grace period")
	w.dropQueue(ctx)
	w.updateHealth(func(health *domain.WorkerHealth) {
		health.Parked = true
		health.ParkedUntil = time.Now().Add(w.deliveryGrace)
		health.LastError = "pushes are not reaching any device"
	})
}

// forgetQueue drops the local cursor without telling the server, which is what a
// collected queue calls for.
func (w *Worker) forgetQueue(ctx context.Context) {
	if err := w.queues.Clear(ctx, w.user.ID); err != nil {
		w.log.Warn("clear queue state", "error", err)
	}
}

// dropQueue deletes the queue on the server as well. The context of the caller
// may already be cancelled during shutdown, so this makes its own.
func (w *Worker) dropQueue(parent context.Context) {
	stored, err := w.queues.Load(parent, w.user.ID)
	if errors.Is(err, repository.ErrNotFound) {
		return
	}
	if err != nil {
		w.log.Warn("load queue state for deletion", "error", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), 15*time.Second)
	defer cancel()

	creds, err := w.users.Credentials(ctx, w.user.ID)
	if err == nil {
		if err := w.zulip.DeleteQueue(ctx, creds, stored.QueueID); err != nil {
			w.log.Warn("delete event queue", "queue_id", stored.QueueID, "error", err)
		}
	}
	if err := w.queues.Clear(ctx, w.user.ID); err != nil {
		w.log.Warn("clear queue state", "error", err)
	}
}

func (w *Worker) recordStatus(ctx context.Context, status domain.UserStatus, detail string) {
	if err := w.users.SetStatus(ctx, w.user.ID, status, detail); err != nil {
		w.log.Warn("record user status", "error", err)
	}
	w.updateHealth(func(health *domain.WorkerHealth) { health.LastError = detail })
}

func (w *Worker) noteError(err error) {
	w.log.Warn("event queue error", "error", err)
	w.updateHealth(func(health *domain.WorkerHealth) { health.LastError = err.Error() })
}

// isTransient separates "the network or the server had a moment" from "this
// build does not understand what came back", which deserves a longer wait and a
// louder log.
func isTransient(err error) bool {
	var apiErr *zulip.APIError
	if errors.As(err, &apiErr) {
		return apiErr.StatusCode >= 500
	}
	return true
}
