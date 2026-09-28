package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"strings"

	"github.com/bwees/zulu/service/internal/apns"
	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/zulip"
)

// deviceSecretBytes is the length of the bearer secret handed back at
// registration. It is the app's credential for every later call, so the Zulip
// API key never has to travel again.
const deviceSecretBytes = 32

// Supervisor is the worker supervisor as this service needs it: something to
// nudge when the set of users changes, and something to ask how a user's queue
// is doing.
type Supervisor interface {
	Reconcile()
	Health(userID int64) domain.WorkerHealth
}

const (
	testNotificationTitle = "Zulu"
	testNotificationBody  = "Notifications are working."
	// testCollapseID replaces the previous test notification instead of stacking.
	testCollapseID = "zulu-test"
)

// DeviceService owns registration, listing, and deregistration of the devices a
// user wants notified.
type DeviceService struct {
	users      *repository.UserRepository
	devices    *repository.DeviceRepository
	zulip      *zulip.Client
	sender     apns.Sender
	supervisor Supervisor
	log        *slog.Logger
}

func NewDeviceService(
	users *repository.UserRepository,
	devices *repository.DeviceRepository,
	zulipClient *zulip.Client,
	sender apns.Sender,
	supervisor Supervisor,
	log *slog.Logger,
) *DeviceService {
	return &DeviceService{
		users:      users,
		devices:    devices,
		zulip:      zulipClient,
		sender:     sender,
		supervisor: supervisor,
		log:        log,
	}
}

// RegisterInput is what the app hands over. The API key is the account's only
// credential — Zulip has no second, scopable one — so handing it here gives this
// service the same access the app has.
type RegisterInput struct {
	RealmURL    string
	Email       string
	APIKey      string
	DeviceToken string
	Platform    string
	Environment string
	AppVersion  string
	// PreviousDeviceSecret is the secret this install got last time, if any. Its
	// row is replaced, so a new token or environment does not leave the old one
	// behind receiving pushes.
	PreviousDeviceSecret string
}

type RegisterOutput struct {
	DeviceID     string
	DeviceSecret string
	UserID       int64
	ZulipUserID  int64
}

func (s *DeviceService) Register(ctx context.Context, input RegisterInput) (RegisterOutput, error) {
	realmURL, err := normaliseRealmURL(input.RealmURL)
	if err != nil {
		return RegisterOutput{}, err
	}
	if err := validateRegisterInput(input); err != nil {
		return RegisterOutput{}, err
	}

	creds := domain.Credentials{RealmURL: realmURL, Email: input.Email, APIKey: input.APIKey}
	owner, err := s.zulip.OwnUser(ctx, creds)
	if err != nil {
		if zulip.IsUnauthorized(err) {
			return RegisterOutput{}, fmt.Errorf("%w: %s", ErrCredentialsRejected, realmURL)
		}
		return RegisterOutput{}, fmt.Errorf("verify credentials: %w", err)
	}
	if owner.IsBot {
		// A bot has its own account and cannot see the owner's direct messages,
		// so it can never back a notification service.
		return RegisterOutput{}, fmt.Errorf("%w: bot accounts cannot be registered", ErrInvalidInput)
	}
	// Zulip's own delivery email is authoritative; what the app sent may differ in
	// case or be an alias.
	creds.Email = owner.Email

	user, err := s.users.Upsert(ctx, creds, owner.UserID)
	if err != nil {
		return RegisterOutput{}, err
	}

	deviceSecret, secretHash, err := newDeviceSecret()
	if err != nil {
		return RegisterOutput{}, err
	}
	deviceID, err := newDeviceID()
	if err != nil {
		return RegisterOutput{}, err
	}

	device, err := s.devices.Upsert(ctx, domain.Device{
		ID:          deviceID,
		UserID:      user.ID,
		Token:       input.DeviceToken,
		Environment: input.Environment,
		Platform:    input.Platform,
		AppVersion:  input.AppVersion,
	}, secretHash)
	if err != nil {
		return RegisterOutput{}, err
	}
	s.replacePreviousDevice(ctx, input.PreviousDeviceSecret, device.ID)

	s.log.Info("device registered",
		"user_id", user.ID,
		"realm", user.RealmURL,
		"device_id", device.ID,
		"platform", device.Platform,
		"environment", device.Environment)
	s.supervisor.Reconcile()

	return RegisterOutput{
		DeviceID:     device.ID,
		DeviceSecret: deviceSecret,
		UserID:       user.ID,
		ZulipUserID:  user.ZulipUserID,
	}, nil
}

// replacePreviousDevice is best effort: registration has already succeeded, and
// a leftover row is also removed once APNs rejects it.
func (s *DeviceService) replacePreviousDevice(ctx context.Context, previousSecret, currentID string) {
	if previousSecret == "" {
		return
	}
	previous, err := s.Authenticate(ctx, previousSecret)
	if err != nil || previous.Device.ID == currentID {
		return
	}
	if err := s.Deregister(ctx, previous.User.ID, previous.Device.ID); err != nil {
		s.log.Warn("replace previous device", "device_id", previous.Device.ID, "error", err)
		return
	}
	s.log.Info("replaced previous device", "device_id", previous.Device.ID, "environment", previous.Device.Environment)
}

// Caller is an authenticated device and the account it belongs to.
type Caller struct {
	Device domain.Device
	User   domain.User
}

// Authenticate resolves the bearer secret the app got at registration.
func (s *DeviceService) Authenticate(ctx context.Context, deviceSecret string) (Caller, error) {
	raw, err := base64.RawURLEncoding.DecodeString(deviceSecret)
	if err != nil || len(raw) != deviceSecretBytes {
		return Caller{}, ErrUnauthenticated
	}

	hash := sha256.Sum256(raw)
	device, err := s.devices.FindBySecretHash(ctx, hash[:])
	if errors.Is(err, repository.ErrNotFound) {
		return Caller{}, ErrUnauthenticated
	}
	if err != nil {
		return Caller{}, err
	}
	user, err := s.users.Get(ctx, device.UserID)
	if errors.Is(err, repository.ErrNotFound) {
		return Caller{}, ErrUnauthenticated
	}
	if err != nil {
		return Caller{}, err
	}

	if err := s.devices.TouchLastSeen(ctx, device.ID); err != nil {
		s.log.Warn("touch device", "device_id", device.ID, "error", err)
	}
	return Caller{Device: device, User: user}, nil
}

func (s *DeviceService) List(ctx context.Context, userID int64) ([]domain.Device, error) {
	return s.devices.ListByUser(ctx, userID)
}

// Deregister removes one device. Removing the last one also removes the stored
// API key: with nothing left to notify, there is no reason to keep a credential
// or an event queue, and dropping the queue hands notification duty back to
// Zulip.
func (s *DeviceService) Deregister(ctx context.Context, userID int64, deviceID string) error {
	device, err := s.devices.Get(ctx, deviceID)
	if errors.Is(err, repository.ErrNotFound) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if device.UserID != userID {
		return ErrNotFound
	}
	if err := s.devices.Delete(ctx, deviceID); err != nil {
		return err
	}

	remaining, err := s.devices.ListByUser(ctx, userID)
	if err != nil {
		return err
	}
	if len(remaining) == 0 {
		if err := s.users.Delete(ctx, userID); err != nil {
			return err
		}
		s.log.Info("account removed after last device deregistered", "user_id", userID)
	}

	s.supervisor.Reconcile()
	return nil
}

// Status is the answer to "are my notifications working?".
type Status struct {
	User    domain.User
	Devices int
	Health  domain.WorkerHealth
}

func (s *DeviceService) Status(ctx context.Context, userID int64) (Status, error) {
	user, err := s.users.Get(ctx, userID)
	if errors.Is(err, repository.ErrNotFound) {
		return Status{}, ErrNotFound
	}
	if err != nil {
		return Status{}, err
	}
	devices, err := s.devices.ListByUser(ctx, userID)
	if err != nil {
		return Status{}, err
	}
	return Status{User: user, Devices: len(devices), Health: s.supervisor.Health(userID)}, nil
}

// SendTest pushes a fixed notification to the calling device only. The receipt
// is returned as-is so the app can show why APNs refused it.
func (s *DeviceService) SendTest(ctx context.Context, caller Caller) (apns.Receipt, error) {
	receipt, err := s.sender.Push(ctx, apns.Notification{
		Token:       caller.Device.Token,
		Environment: caller.Device.Environment,
		CollapseID:  testCollapseID,
		Payload: apns.Payload{
			Title:             testNotificationTitle,
			Body:              testNotificationBody,
			Sound:             "default",
			InterruptionLevel: "active",
			Custom:            map[string]any{"realmUrl": caller.User.RealmURL},
		},
	})
	if err != nil {
		return apns.Receipt{}, err
	}
	s.log.Info("test notification",
		"device_id", caller.Device.ID,
		"status", receipt.StatusCode,
		"reason", receipt.Reason)
	return receipt, nil
}

func validateRegisterInput(input RegisterInput) error {
	if strings.TrimSpace(input.Email) == "" {
		return fmt.Errorf("%w: email is required", ErrInvalidInput)
	}
	if strings.TrimSpace(input.APIKey) == "" {
		return fmt.Errorf("%w: apiKey is required", ErrInvalidInput)
	}
	if !validDeviceToken(input.DeviceToken) {
		return fmt.Errorf("%w: deviceToken must be a hex string", ErrInvalidInput)
	}
	if !domain.ValidPlatform(input.Platform) {
		return fmt.Errorf("%w: platform must be %q or %q", ErrInvalidInput, domain.PlatformIOS, domain.PlatformMacOS)
	}
	if !domain.ValidEnvironment(input.Environment) {
		return fmt.Errorf("%w: environment must be %q or %q", ErrInvalidInput, domain.EnvironmentProduction, domain.EnvironmentSandbox)
	}
	return nil
}

// validDeviceToken checks the shape only. Apple tells senders never to assume a
// token length, so the length is not checked.
func validDeviceToken(token string) bool {
	if token == "" {
		return false
	}
	_, err := hex.DecodeString(token)
	return err == nil
}

func normaliseRealmURL(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", fmt.Errorf("%w: realmUrl is not a URL", ErrInvalidInput)
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return "", fmt.Errorf("%w: realmUrl must be http or https", ErrInvalidInput)
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("%w: realmUrl has no host", ErrInvalidInput)
	}
	return strings.TrimSuffix(parsed.Scheme+"://"+parsed.Host+parsed.Path, "/"), nil
}

func newDeviceSecret() (string, []byte, error) {
	raw := make([]byte, deviceSecretBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, fmt.Errorf("service: generate device secret: %w", err)
	}
	hash := sha256.Sum256(raw)
	return base64.RawURLEncoding.EncodeToString(raw), hash[:], nil
}

func newDeviceID() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("service: generate device id: %w", err)
	}
	return hex.EncodeToString(raw), nil
}
