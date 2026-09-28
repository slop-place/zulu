package service_test

import (
	"bytes"
	"context"
	"database/sql"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/apns"
	"github.com/bwees/zulu/service/internal/database"
	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/secret"
	"github.com/bwees/zulu/service/internal/service"
	"github.com/bwees/zulu/service/internal/zulip"
)

func newTestDatabase(t *testing.T) *sql.DB {
	t.Helper()
	db, err := database.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })
	return db
}

func newTestSealer(t *testing.T) *secret.Sealer {
	t.Helper()
	sealer, err := secret.NewSealer(bytes.Repeat([]byte{5}, 32))
	require.NoError(t, err)
	return sealer
}

func newTestLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// fakeSupervisor counts the nudges the service sends when the user set changes.
type fakeSupervisor struct {
	reconciles atomic.Int64
	health     domain.WorkerHealth
}

func (s *fakeSupervisor) Reconcile()                       { s.reconciles.Add(1) }
func (s *fakeSupervisor) Health(int64) domain.WorkerHealth { return s.health }

// fakeZulip serves just enough of GET /users/me to register against.
func fakeZulip(t *testing.T, body string, status int) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/api/v1/users/me", r.URL.Path)
		assert.NotEmpty(t, r.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		io.WriteString(w, body)
	}))
	t.Cleanup(server.Close)
	return server
}

type deviceFixture struct {
	devices    *service.DeviceService
	sender     *recordingSender
	supervisor *fakeSupervisor
	realmURL   string
}

func newDeviceFixture(t *testing.T, zulipServer *httptest.Server) deviceFixture {
	t.Helper()
	db := newTestDatabase(t)
	sender := &recordingSender{}
	supervisor := &fakeSupervisor{}
	return deviceFixture{
		devices: service.NewDeviceService(
			repository.NewUserRepository(db, newTestSealer(t)),
			repository.NewDeviceRepository(db),
			zulip.NewClient(),
			sender,
			supervisor,
			newTestLogger(),
		),
		sender:     sender,
		supervisor: supervisor,
		realmURL:   zulipServer.URL,
	}
}

func (f deviceFixture) input() service.RegisterInput {
	return service.RegisterInput{
		RealmURL:    f.realmURL + "/",
		Email:       "user@example.com",
		APIKey:      "key",
		DeviceToken: "0a1b2c",
		Platform:    domain.PlatformIOS,
		Environment: domain.EnvironmentProduction,
		AppVersion:  "1.0",
	}
}

func TestRegisterStartsWatchingTheAccount(t *testing.T) {
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "canonical@example.com"}`, 200))

	output, err := fixture.devices.Register(context.Background(), fixture.input())

	require.NoError(t, err)
	assert.Equal(t, int64(12), output.ZulipUserID)
	assert.NotEmpty(t, output.DeviceSecret)
	assert.Equal(t, int64(1), fixture.supervisor.reconciles.Load())

	caller, err := fixture.devices.Authenticate(context.Background(), output.DeviceSecret)
	require.NoError(t, err)
	assert.Equal(t, output.DeviceID, caller.Device.ID)
	assert.Equal(t, "canonical@example.com", caller.User.Email, "Zulip's delivery email wins over what the app sent")
}

func TestSendTestPushesOnlyToTheCallingDevice(t *testing.T) {
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "user@example.com"}`, 200))
	first, err := fixture.devices.Register(context.Background(), fixture.input())
	require.NoError(t, err)
	second := fixture.input()
	second.DeviceToken = "ffee"
	_, err = fixture.devices.Register(context.Background(), second)
	require.NoError(t, err)

	caller, err := fixture.devices.Authenticate(context.Background(), first.DeviceSecret)
	require.NoError(t, err)
	fixture.sender.receipts = []apns.Receipt{{StatusCode: 400, Reason: apns.ReasonBadDeviceToken}}

	receipt, err := fixture.devices.SendTest(context.Background(), caller)

	require.NoError(t, err)
	assert.Equal(t, apns.ReasonBadDeviceToken, receipt.Reason)
	require.Len(t, fixture.sender.sent, 1)
	assert.Equal(t, "0a1b2c", fixture.sender.sent[0].Token)
	assert.Equal(t, domain.EnvironmentProduction, fixture.sender.sent[0].Environment)
}

func TestRegisterRejectsBadInput(t *testing.T) {
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "user@example.com"}`, 200))

	tests := []struct {
		name   string
		mutate func(*service.RegisterInput)
	}{
		{name: "no realm scheme", mutate: func(in *service.RegisterInput) { in.RealmURL = "chat.example.com" }},
		{name: "no api key", mutate: func(in *service.RegisterInput) { in.APIKey = "" }},
		{name: "token is not hex", mutate: func(in *service.RegisterInput) { in.DeviceToken = "not-a-token" }},
		{name: "unknown platform", mutate: func(in *service.RegisterInput) { in.Platform = "android" }},
		{name: "unknown environment", mutate: func(in *service.RegisterInput) { in.Environment = "staging" }},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			input := fixture.input()
			test.mutate(&input)

			_, err := fixture.devices.Register(context.Background(), input)

			assert.ErrorIs(t, err, service.ErrInvalidInput)
		})
	}
}

func TestRegisterRejectsABadKey(t *testing.T) {
	fixture := newDeviceFixture(t, fakeZulip(t, `{"result": "error", "msg": "Invalid API key"}`, 401))

	_, err := fixture.devices.Register(context.Background(), fixture.input())

	assert.ErrorIs(t, err, service.ErrCredentialsRejected)
}

// A bot has its own account and cannot see the owner's direct messages.
func TestRegisterRejectsBots(t *testing.T) {
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "bot@example.com", "is_bot": true}`, 200))

	_, err := fixture.devices.Register(context.Background(), fixture.input())

	assert.ErrorIs(t, err, service.ErrInvalidInput)
}

func TestAuthenticateRejectsAnUnknownSecret(t *testing.T) {
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "user@example.com"}`, 200))

	_, err := fixture.devices.Authenticate(context.Background(), "not-a-secret")

	assert.ErrorIs(t, err, service.ErrUnauthenticated)
}

func TestDeregisterLastDeviceDropsTheStoredKey(t *testing.T) {
	ctx := context.Background()
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "user@example.com"}`, 200))
	first, err := fixture.devices.Register(ctx, fixture.input())
	require.NoError(t, err)
	secondInput := fixture.input()
	secondInput.DeviceToken = "ff00"
	second, err := fixture.devices.Register(ctx, secondInput)
	require.NoError(t, err)

	require.NoError(t, fixture.devices.Deregister(ctx, second.UserID, first.DeviceID))
	remaining, err := fixture.devices.List(ctx, second.UserID)
	require.NoError(t, err)
	assert.Len(t, remaining, 1, "the account survives while another device is registered")

	require.NoError(t, fixture.devices.Deregister(ctx, second.UserID, second.DeviceID))
	_, err = fixture.devices.Status(ctx, second.UserID)
	assert.ErrorIs(t, err, service.ErrNotFound, "the account and its API key are gone")
}

// A release build installed over a debug build has a new token in a new
// environment. The debug build's row must not linger and keep failing.
func TestRegisteringAgainReplacesTheInstallsOldDevice(t *testing.T) {
	ctx := context.Background()
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "user@example.com"}`, 200))
	debugInput := fixture.input()
	debugInput.Environment = domain.EnvironmentSandbox
	debug, err := fixture.devices.Register(ctx, debugInput)
	require.NoError(t, err)

	releaseInput := fixture.input()
	releaseInput.DeviceToken = "ff00"
	releaseInput.PreviousDeviceSecret = debug.DeviceSecret
	release, err := fixture.devices.Register(ctx, releaseInput)
	require.NoError(t, err)

	remaining, err := fixture.devices.List(ctx, release.UserID)
	require.NoError(t, err)
	require.Len(t, remaining, 1)
	assert.Equal(t, release.DeviceID, remaining[0].ID)
	assert.Equal(t, domain.EnvironmentProduction, remaining[0].Environment)
}

func TestDeregisterRefusesAnotherAccountsDevice(t *testing.T) {
	ctx := context.Background()
	fixture := newDeviceFixture(t, fakeZulip(t, `{"user_id": 12, "email": "user@example.com"}`, 200))
	registered, err := fixture.devices.Register(ctx, fixture.input())
	require.NoError(t, err)

	err = fixture.devices.Deregister(ctx, registered.UserID+1, registered.DeviceID)

	assert.ErrorIs(t, err, service.ErrNotFound)
}
