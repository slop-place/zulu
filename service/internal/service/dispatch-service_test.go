package service_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/apns"
	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/notify"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/service"
	"github.com/bwees/zulu/service/internal/zulip"
)

// recordingSender stands in for APNs. Each queued receipt answers one push.
type recordingSender struct {
	sent     []apns.Notification
	receipts []apns.Receipt
	err      error
}

func (s *recordingSender) Push(_ context.Context, notification apns.Notification) (apns.Receipt, error) {
	s.sent = append(s.sent, notification)
	if s.err != nil {
		return apns.Receipt{}, s.err
	}
	if len(s.receipts) == 0 {
		return apns.Receipt{Sent: true, StatusCode: 200}, nil
	}
	receipt := s.receipts[0]
	s.receipts = s.receipts[1:]
	return receipt, nil
}

func channelEvent(t *testing.T) zulip.MessageEvent {
	t.Helper()
	var event zulip.Event
	require.NoError(t, json.Unmarshal([]byte(`{"id": 1, "type": "message", "flags": ["mentioned"], "message": {
		"id": 555, "type": "stream", "sender_id": 42, "sender_full_name": "Ada Lovelace",
		"stream_id": 9, "subject": "Deploys", "display_recipient": "engineering",
		"content": "ship it", "timestamp": 1700000000}}`), &event))
	message, err := zulip.DecodeMessageEvent(event)
	require.NoError(t, err)
	return message
}

func directEvent(t *testing.T) zulip.MessageEvent {
	t.Helper()
	var event zulip.Event
	require.NoError(t, json.Unmarshal([]byte(`{"id": 2, "type": "message", "flags": [], "message": {
		"id": 556, "type": "private", "sender_id": 42, "sender_full_name": "Ada Lovelace",
		"display_recipient": [{"id": 42}, {"id": 12}, {"id": 7}],
		"content": "hello", "timestamp": 1700000000}}`), &event))
	message, err := zulip.DecodeMessageEvent(event)
	require.NoError(t, err)
	return message
}

type dispatchFixture struct {
	dispatch *service.DispatchService
	sender   *recordingSender
	user     domain.User
	devices  *repository.DeviceRepository
}

func newDispatchFixture(t *testing.T, deviceCount int) dispatchFixture {
	t.Helper()
	ctx := context.Background()
	db := newTestDatabase(t)
	users := repository.NewUserRepository(db, newTestSealer(t))
	devices := repository.NewDeviceRepository(db)
	deliveries := repository.NewDeliveryRepository(db)
	sender := &recordingSender{}

	user, err := users.Upsert(ctx, domain.Credentials{
		RealmURL: "https://chat.example.com", Email: "user@example.com", APIKey: "key",
	}, 12)
	require.NoError(t, err)

	for index := range deviceCount {
		_, err := devices.Upsert(ctx, domain.Device{
			ID:          string(rune('a' + index)),
			UserID:      user.ID,
			Token:       string(rune('a'+index)) + "0ff",
			Environment: domain.EnvironmentProduction,
			Platform:    domain.PlatformIOS,
		}, []byte{byte(index)})
		require.NoError(t, err)
	}

	return dispatchFixture{
		dispatch: service.NewDispatchService(devices, deliveries, sender, newTestLogger()),
		sender:   sender,
		user:     user,
		devices:  devices,
	}
}

func TestDispatchReachesEveryDevice(t *testing.T) {
	fixture := newDispatchFixture(t, 3)

	result, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, channelEvent(t),
		notify.Decision{Notify: true, Trigger: notify.TriggerMention})

	require.NoError(t, err)
	assert.Equal(t, 3, result.Attempted)
	assert.Equal(t, 3, result.Delivered)

	collapseIDs := map[string]bool{}
	for _, notification := range fixture.sender.sent {
		collapseIDs[notification.CollapseID] = true
	}
	assert.Len(t, collapseIDs, 1, "one message has one identity on every device, so any device can dismiss it")
	assert.LessOrEqual(t, len(fixture.sender.sent[0].CollapseID), apns.MaxCollapseIDBytes)
}

func TestDispatchIsIdempotentForAReplayedEvent(t *testing.T) {
	fixture := newDispatchFixture(t, 1)
	event := channelEvent(t)
	decision := notify.Decision{Notify: true, Trigger: notify.TriggerMention}

	_, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, event, decision)
	require.NoError(t, err)
	second, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, event, decision)
	require.NoError(t, err)

	assert.Equal(t, 0, second.Attempted)
	assert.Len(t, fixture.sender.sent, 1)
}

func TestDispatchRetriesAfterATransportFailure(t *testing.T) {
	fixture := newDispatchFixture(t, 1)
	fixture.sender.err = errors.New("connection reset")
	event := channelEvent(t)
	decision := notify.Decision{Notify: true, Trigger: notify.TriggerMention}

	first, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, event, decision)
	require.NoError(t, err)
	assert.Equal(t, 0, first.Delivered)

	fixture.sender.err = nil
	second, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, event, decision)
	require.NoError(t, err)
	assert.Equal(t, 1, second.Delivered, "a push APNs never answered is not deduplicated away")
}

func TestDispatchReapsDeadTokens(t *testing.T) {
	tests := []struct {
		name    string
		receipt apns.Receipt
		removed int
	}{
		{
			name:    "unregistered token is removed",
			receipt: apns.Receipt{StatusCode: 410, Reason: apns.ReasonUnregistered, Timestamp: time.Now().Add(time.Hour)},
			removed: 1,
		},
		{
			name:    "a token re-registered after APNs retired it is kept",
			receipt: apns.Receipt{StatusCode: 410, Reason: apns.ReasonUnregistered, Timestamp: time.Now().Add(-48 * time.Hour)},
			removed: 0,
		},
		{
			name:    "a bad device token is kept, because a misconfigured topic looks the same",
			receipt: apns.Receipt{StatusCode: 400, Reason: apns.ReasonBadDeviceToken},
			removed: 0,
		},
		{
			name:    "a token in an environment the key cannot reach is removed",
			receipt: apns.Receipt{StatusCode: 403, Reason: apns.ReasonBadEnvironmentKeyInToken},
			removed: 1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newDispatchFixture(t, 1)
			fixture.sender.receipts = []apns.Receipt{test.receipt}

			result, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, channelEvent(t),
				notify.Decision{Notify: true, Trigger: notify.TriggerMention})

			require.NoError(t, err)
			assert.Equal(t, test.removed, result.RemovedTokens)
			remaining, err := fixture.devices.ListByUser(context.Background(), fixture.user.ID)
			require.NoError(t, err)
			assert.Len(t, remaining, 1-test.removed)
		})
	}
}

func TestChannelPayload(t *testing.T) {
	fixture := newDispatchFixture(t, 1)

	_, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, channelEvent(t),
		notify.Decision{Notify: true, Trigger: notify.TriggerMention})
	require.NoError(t, err)

	payload := fixture.sender.sent[0].Payload
	assert.Equal(t, "#engineering > Deploys", payload.Title)
	assert.Equal(t, "Ada Lovelace", payload.Subtitle)
	assert.Equal(t, "ship it", payload.Body)
	assert.Equal(t, "z:stream:9:deploys", payload.ThreadID)
	assert.Equal(t, "mentioned", payload.Custom["trigger"])
	assert.Equal(t, int64(555), payload.Custom["zulipMessageId"])
	assert.Equal(t, "https://chat.example.com", payload.Custom["realmUrl"])
}

func TestDirectMessagePayload(t *testing.T) {
	fixture := newDispatchFixture(t, 1)

	_, err := fixture.dispatch.Dispatch(context.Background(), fixture.user, directEvent(t),
		notify.Decision{Notify: true, Trigger: notify.TriggerDirectMessage})
	require.NoError(t, err)

	payload := fixture.sender.sent[0].Payload
	assert.Equal(t, "Ada Lovelace", payload.Title)
	assert.Equal(t, "Group direct message", payload.Subtitle)
	assert.Equal(t, "z:dm:7,12,42", payload.ThreadID)
}

// Custom keys must sit beside `aps`, not inside it: APNs discards unknown keys
// within `aps`.
func TestPayloadJSONShape(t *testing.T) {
	payload := apns.Payload{
		Title:          "#engineering > Deploys",
		Body:           "ship it",
		ThreadID:       "z:stream:9:deploys",
		Category:       "ZULU_MESSAGE",
		MutableContent: true,
		Custom:         map[string]any{"zulipMessageId": 555},
	}

	encoded, err := json.Marshal(payload)
	require.NoError(t, err)

	var decoded map[string]any
	require.NoError(t, json.Unmarshal(encoded, &decoded))
	aps, ok := decoded["aps"].(map[string]any)
	require.True(t, ok)
	assert.Equal(t, "ship it", aps["alert"].(map[string]any)["body"])
	assert.Equal(t, "z:stream:9:deploys", aps["thread-id"])
	assert.Equal(t, float64(1), aps["mutable-content"])
	assert.Equal(t, float64(555), decoded["zulipMessageId"])
	assert.NotContains(t, aps, "zulipMessageId")
}
