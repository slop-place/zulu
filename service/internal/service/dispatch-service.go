package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/bwees/zulu/service/internal/apns"
	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/notify"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/zulip"
)

const (
	// notificationCategory must match the UNNotificationCategory the app
	// registers, or its actions never appear.
	notificationCategory = "ZULU_MESSAGE"
	// maxBodyBytes keeps the whole payload inside Apple's 4 KB limit with room
	// for the custom keys.
	maxBodyBytes = 1200
	// collapsePrefix and threadPrefix namespace the identifiers so they never
	// collide with anything else the app might deliver.
	collapsePrefix = "z"
	threadPrefix   = "z"
)

// DispatchService turns one notifiable message into pushes to a user's devices.
type DispatchService struct {
	devices    *repository.DeviceRepository
	deliveries *repository.DeliveryRepository
	sender     apns.Sender
	log        *slog.Logger
}

func NewDispatchService(
	devices *repository.DeviceRepository,
	deliveries *repository.DeliveryRepository,
	sender apns.Sender,
	log *slog.Logger,
) *DispatchService {
	return &DispatchService{devices: devices, deliveries: deliveries, sender: sender, log: log}
}

// DispatchResult tells the caller how the fan-out went. The worker uses it to
// decide whether this service is still able to notify the user at all.
type DispatchResult struct {
	Attempted     int
	Delivered     int
	RemovedTokens int
}

// Dispatch pushes a decided notification to every device the user registered.
//
// Every device gets every push: the service cannot know which handset the user
// is holding, and the app dismisses the duplicates it does not need using the
// collapse identifier this builds.
func (s *DispatchService) Dispatch(
	ctx context.Context,
	user domain.User,
	event zulip.MessageEvent,
	decision notify.Decision,
) (DispatchResult, error) {
	devices, err := s.devices.ListByUser(ctx, user.ID)
	if err != nil {
		return DispatchResult{}, err
	}

	notification := apns.Notification{
		CollapseID: collapseID(user.RealmURL, event.Message.ID),
		Payload:    buildPayload(user, event, decision),
	}

	result := DispatchResult{}
	for _, device := range devices {
		claimed, err := s.deliveries.Claim(ctx, user.ID, device.ID, event.Message.ID, string(decision.Trigger))
		if err != nil {
			return result, err
		}
		if !claimed {
			continue
		}

		result.Attempted++
		notification.Token = device.Token
		notification.Environment = device.Environment

		receipt, err := s.sender.Push(ctx, notification)
		if err != nil {
			// APNs never answered. Drop the claim so a redelivered event can try
			// again rather than being deduplicated into silence.
			if releaseErr := s.deliveries.Release(ctx, user.ID, device.ID, event.Message.ID); releaseErr != nil {
				s.log.Warn("release delivery claim", "device_id", device.ID, "error", releaseErr)
			}
			s.log.Warn("apns push failed", "user_id", user.ID, "device_id", device.ID, "error", err)
			continue
		}

		if receipt.Sent {
			result.Delivered++
			if err := s.deliveries.Complete(ctx, user.ID, device.ID, event.Message.ID, repository.DeliverySent, ""); err != nil {
				return result, err
			}
			continue
		}

		detail := strconv.Itoa(receipt.StatusCode) + " " + receipt.Reason
		if err := s.deliveries.Complete(ctx, user.ID, device.ID, event.Message.ID, repository.DeliveryFailed, detail); err != nil {
			return result, err
		}
		if s.reapDeadToken(ctx, device, receipt) {
			result.RemovedTokens++
		}
	}
	return result, nil
}

// reapDeadToken removes a token APNs has retired, or one the key cannot reach. A
// retired token is kept if the app re-registered it after APNs made that call,
// which Apple documents as possible.
func (s *DispatchService) reapDeadToken(ctx context.Context, device domain.Device, receipt apns.Receipt) bool {
	switch {
	case receipt.EnvironmentIsRefused():
	case !receipt.TokenIsDead():
		return false
	case !receipt.Timestamp.IsZero() && device.RegisteredAt.After(receipt.Timestamp):
		return false
	}
	if err := s.devices.Delete(ctx, device.ID); err != nil {
		s.log.Warn("delete dead device", "device_id", device.ID, "error", err)
		return false
	}
	s.log.Info("removed dead device token", "device_id", device.ID, "reason", receipt.Reason)
	return true
}

func buildPayload(user domain.User, event zulip.MessageEvent, decision notify.Decision) apns.Payload {
	message := event.Message

	payload := apns.Payload{
		Body:              truncateBody(message.Content),
		Category:          notificationCategory,
		Sound:             "default",
		InterruptionLevel: "active",
		// The service extension re-renders the notification on device: avatars,
		// custom emoji, and communication-notification styling.
		MutableContent: true,
		Custom: map[string]any{
			"realmUrl":       user.RealmURL,
			"zulipUserId":    user.ZulipUserID,
			"zulipMessageId": message.ID,
			"senderId":       message.SenderID,
			"senderName":     message.SenderFullName,
			"trigger":        string(decision.Trigger),
			"timestamp":      message.Timestamp,
		},
	}

	if message.Type == notify.MessageTypeStream {
		channel := message.ChannelName()
		payload.Title = channelHeading(channel, message.Subject)
		payload.Subtitle = message.SenderFullName
		payload.ThreadID = channelThreadID(message.StreamID, message.Subject)
		payload.Custom["zulipStreamId"] = message.StreamID
		payload.Custom["zulipChannel"] = channel
		payload.Custom["zulipTopic"] = message.Subject
		return payload
	}

	recipients := message.RecipientIDs()
	payload.Title = message.SenderFullName
	if len(recipients) > 2 {
		payload.Subtitle = "Group direct message"
	}
	payload.ThreadID = directThreadID(recipients)
	payload.Custom["zulipRecipientIds"] = recipients
	return payload
}

func channelHeading(channel, topic string) string {
	if topic == "" {
		return "#" + channel
	}
	return "#" + channel + " > " + topic
}

// channelThreadID groups a channel's notifications by topic, matching how the
// app groups conversations. Topics fold case because Zulip treats them that way.
func channelThreadID(streamID int64, topic string) string {
	return threadPrefix + ":stream:" + strconv.FormatInt(streamID, 10) + ":" + notify.FoldTopic(topic)
}

func directThreadID(recipientIDs []int64) string {
	ids := make([]string, 0, len(recipientIDs))
	for _, id := range recipientIDs {
		ids = append(ids, strconv.FormatInt(id, 10))
	}
	return threadPrefix + ":dm:" + strings.Join(ids, ",")
}

// collapseID gives the delivered notification the same identifier on every
// device, which is what makes cross-device dismissal possible: there is no APNs
// delete API, so the app can only remove a notification it can name. Message ids
// are unique per realm, so the realm is hashed in to keep it unique for a device
// signed into more than one.
func collapseID(realmURL string, messageID int64) string {
	digest := sha256.Sum256([]byte(realmURL))
	id := collapsePrefix + ":" + hex.EncodeToString(digest[:4]) + ":" + strconv.FormatInt(messageID, 10)
	if len(id) > apns.MaxCollapseIDBytes {
		return id[:apns.MaxCollapseIDBytes]
	}
	return id
}

func truncateBody(body string) string {
	if len(body) <= maxBodyBytes {
		return body
	}
	truncated := body[:maxBodyBytes]
	for len(truncated) > 0 && !utf8.ValidString(truncated) {
		truncated = truncated[:len(truncated)-1]
	}
	return truncated + "…"
}

// DecisionInput adapts a Zulip message event to the resolver's input.
func DecisionInput(user domain.User, event zulip.MessageEvent, state *notify.State) notify.Input {
	return notify.Input{
		UserID: user.ZulipUserID,
		Message: notify.Message{
			ID:       event.Message.ID,
			Type:     event.Message.Type,
			SenderID: event.Message.SenderID,
			StreamID: event.Message.StreamID,
			Topic:    event.Message.Subject,
		},
		Flags: event.Flags,
		State: state,
	}
}
