package notify_test

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/notify"
)

// rulesFile is shared with the apps' tests, so both sides answer the same cases.
const rulesFile = "../../../spec/notification-rules.json"

const (
	recipientID = int64(7)
	senderID    = int64(42)
	channelID   = int64(100)
	topic       = "deploys"
)

func boolPtr(value bool) *bool { return &value }

type ruleCase struct {
	Name           string   `json:"name"`
	Direct         bool     `json:"direct"`
	Own            bool     `json:"own"`
	SenderMuted    bool     `json:"senderMuted"`
	Flags          []string `json:"flags"`
	ChannelMuted   bool     `json:"channelMuted"`
	ChannelPush    *bool    `json:"channelPush"`
	TopicPolicy    string   `json:"topicPolicy"`
	DirectMessages bool     `json:"directMessages"`
	Mentions       bool     `json:"mentions"`
	Level          *string  `json:"level"`
	Notify         bool     `json:"notify"`
}

var policies = map[string]notify.VisibilityPolicy{
	"inherit":  notify.PolicyInherit,
	"muted":    notify.PolicyMuted,
	"unmuted":  notify.PolicyUnmuted,
	"followed": notify.PolicyFollowed,
}

func loadRuleCases(t *testing.T) []ruleCase {
	t.Helper()
	raw, err := os.ReadFile(rulesFile)
	require.NoError(t, err)
	var file struct {
		Cases []ruleCase `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(raw, &file))
	require.NotEmpty(t, file.Cases)
	return file.Cases
}

func (c ruleCase) input() notify.Input {
	state := notify.NewState()
	// The service has one Zulip toggle for both, so each case sets the one it reads.
	if c.Direct {
		state.Global.EnableOfflinePushNotifications = c.DirectMessages
	} else {
		state.Global.EnableOfflinePushNotifications = c.Mentions
	}
	state.SetSubscription(channelID, notify.Subscription{IsMuted: c.ChannelMuted, PushNotifications: c.ChannelPush})
	state.SetTopicPolicy(channelID, topic, policies[c.TopicPolicy])
	if c.SenderMuted {
		state.SetMutedUsers([]int64{senderID})
	}

	message := notify.Message{ID: 1, Type: notify.MessageTypeStream, SenderID: senderID, StreamID: channelID, Topic: topic}
	if c.Direct {
		message = notify.Message{ID: 1, Type: notify.MessageTypePrivate, SenderID: senderID}
	}
	if c.Own {
		message.SenderID = recipientID
	}
	return notify.Input{UserID: recipientID, Message: message, Flags: c.Flags, State: state}
}

func TestSharedRules(t *testing.T) {
	for _, c := range loadRuleCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			decision := notify.Decide(c.input())
			assert.Equal(t, c.Notify, decision.Notify, "reason: %s", decision.Reason)

			if c.Level == nil {
				return
			}
			level, fromTopic := notify.TopicLevel(policies[c.TopicPolicy])
			if !fromTopic {
				level = notify.ChannelLevel(notify.Subscription{IsMuted: c.ChannelMuted, PushNotifications: c.ChannelPush})
			}
			assert.Equal(t, notify.Level(*c.Level), level)
		})
	}
}

func TestAMentionOutranksTheLevel(t *testing.T) {
	state := notify.NewState()
	state.SetSubscription(channelID, notify.Subscription{PushNotifications: boolPtr(true)})

	decision := notify.Decide(notify.Input{
		UserID:  recipientID,
		Message: notify.Message{ID: 1, Type: notify.MessageTypeStream, SenderID: senderID, StreamID: channelID, Topic: topic},
		Flags:   []string{notify.FlagMentioned},
		State:   state,
	})

	assert.Equal(t, notify.TriggerMention, decision.Trigger)
}

func TestAFollowedTopicGetsItsOwnTrigger(t *testing.T) {
	state := notify.NewState()
	state.SetTopicPolicy(channelID, topic, notify.PolicyFollowed)

	decision := notify.Decide(notify.Input{
		UserID:  recipientID,
		Message: notify.Message{ID: 1, Type: notify.MessageTypeStream, SenderID: senderID, StreamID: channelID, Topic: topic},
		State:   state,
	})

	assert.Equal(t, notify.TriggerFollowedTopicPush, decision.Trigger)
}

func TestTopicPoliciesMatchWhateverTheirCase(t *testing.T) {
	state := notify.NewState()
	state.SetTopicPolicy(channelID, "DePloYs", notify.PolicyFollowed)

	decision := notify.Decide(notify.Input{
		UserID:  recipientID,
		Message: notify.Message{ID: 1, Type: notify.MessageTypeStream, SenderID: senderID, StreamID: channelID, Topic: topic},
		State:   state,
	})

	assert.True(t, decision.Notify)
}

// Zulip's global channel push toggle is invisible in the apps, so it must not
// turn a channel nobody configured into All Messages.
func TestTheGlobalChannelToggleIsIgnored(t *testing.T) {
	state := notify.NewState()
	state.Global.EnableStreamPushNotifications = true

	decision := notify.Decide(notify.Input{
		UserID:  recipientID,
		Message: notify.Message{ID: 1, Type: notify.MessageTypeStream, SenderID: senderID, StreamID: channelID, Topic: topic},
		State:   state,
	})

	assert.False(t, decision.Notify)
}

func TestDecideWithoutState(t *testing.T) {
	decision := notify.Decide(notify.Input{
		UserID:  recipientID,
		Message: notify.Message{ID: 2, Type: notify.MessageTypePrivate, SenderID: senderID},
	})

	assert.True(t, decision.Notify, "an empty mirror falls back to Zulip's defaults")
	assert.Equal(t, notify.TriggerDirectMessage, decision.Trigger)
}
