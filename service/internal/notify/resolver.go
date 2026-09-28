package notify

// Trigger is Zulip's NotificationTriggers vocabulary. The server uses it only to
// pick an alert subtitle; this service uses it the same way.
type Trigger string

const (
	TriggerNone                  Trigger = ""
	TriggerDirectMessage         Trigger = "direct_message"
	TriggerMention               Trigger = "mentioned"
	TriggerTopicWildcardMention  Trigger = "topic_wildcard_mentioned"
	TriggerStreamWildcardMention Trigger = "stream_wildcard_mentioned"
	TriggerFollowedTopicPush     Trigger = "followed_topic_push_notify"
	TriggerStreamPush            Trigger = "stream_push_notify"
)

// Message flags set by the server. They are the only trustworthy mention signal:
// wildcard syntax inside a code block sets no flag, and a silent mention sets none
// either, so the message body must never be re-parsed to find mentions.
const (
	FlagRead                    = "read"
	FlagMentioned               = "mentioned"
	FlagStreamWildcardMentioned = "stream_wildcard_mentioned"
	FlagTopicWildcardMentioned  = "topic_wildcard_mentioned"
	// FlagWildcardMentioned is the pre-feature-level-224 flag, equivalent to a
	// stream wildcard mention.
	FlagWildcardMentioned = "wildcard_mentioned"
)

const (
	MessageTypeStream  = "stream"
	MessageTypePrivate = "private"
)

// Level is how loudly a channel or topic notifies. It is the same three levels
// the Zulu apps show, read from the same Zulip settings, so a push and a banner
// always agree with what the menu says.
type Level string

const (
	LevelAll      Level = "all"
	LevelMentions Level = "mentions"
	LevelMuted    Level = "muted"
)

// Message is the subset of a Zulip message event the decision reads.
type Message struct {
	ID       int64
	Type     string
	SenderID int64
	StreamID int64
	Topic    string
}

// Input is everything the decision needs.
type Input struct {
	UserID  int64
	Message Message
	Flags   []string
	State   *State
}

// Decision is the outcome. Reason names the rule that produced it and exists for
// logs and tests, not for the payload.
type Decision struct {
	Notify  bool
	Trigger Trigger
	Reason  string
}

func suppress(reason string) Decision { return Decision{Reason: reason} }

func fire(trigger Trigger) Decision {
	return Decision{Notify: true, Trigger: trigger, Reason: string(trigger)}
}

// TopicLevel is the topic's own level, or false when it follows its channel.
func TopicLevel(policy VisibilityPolicy) (Level, bool) {
	switch policy {
	case PolicyFollowed:
		return LevelAll, true
	case PolicyUnmuted:
		return LevelMentions, true
	case PolicyMuted:
		return LevelMuted, true
	default:
		return "", false
	}
}

// ChannelLevel ignores Zulip's global channel push setting on purpose: the apps
// cannot see it, and a channel nobody configured reads as Mentions Only there.
func ChannelLevel(sub Subscription) Level {
	switch {
	case sub.IsMuted:
		return LevelMuted
	case sub.PushNotifications != nil && *sub.PushNotifications:
		return LevelAll
	default:
		return LevelMentions
	}
}

// Decide answers whether a message event should become a push for one user. The
// rules are shared with the apps through spec/notification-rules.json.
func Decide(in Input) Decision {
	state := in.State
	if state == nil {
		state = NewState()
	}
	flags := newFlagSet(in.Flags)
	mentionsAllowed := state.Global.EnableOfflinePushNotifications

	if in.Message.SenderID == in.UserID {
		return suppress("own message")
	}
	if state.IsMutedUser(in.Message.SenderID) {
		return suppress("muted sender")
	}
	// A message can arrive already read: the docs warn that new messages are not
	// necessarily unread.
	if flags.has(FlagRead) {
		return suppress("already read")
	}

	if in.Message.Type == MessageTypePrivate {
		if mentionsAllowed {
			return fire(TriggerDirectMessage)
		}
		return suppress("direct message notifications are off")
	}

	policy := state.TopicPolicy(in.Message.StreamID, in.Message.Topic)
	level, fromTopic := TopicLevel(policy)
	if !fromTopic {
		level = ChannelLevel(state.Subscription(in.Message.StreamID))
	}

	if mentionsAllowed && flags.has(FlagMentioned) {
		return fire(TriggerMention)
	}
	if mentionsAllowed && level != LevelMuted {
		switch {
		case flags.has(FlagTopicWildcardMentioned):
			return fire(TriggerTopicWildcardMention)
		case flags.hasStreamWildcard():
			return fire(TriggerStreamWildcardMention)
		}
	}
	if level == LevelAll {
		if fromTopic {
			return fire(TriggerFollowedTopicPush)
		}
		return fire(TriggerStreamPush)
	}
	return suppress("level is " + string(level))
}

type flagSet map[string]bool

func newFlagSet(flags []string) flagSet {
	set := make(flagSet, len(flags))
	for _, flag := range flags {
		set[flag] = true
	}
	return set
}

func (f flagSet) has(flag string) bool { return f[flag] }

// hasStreamWildcard folds in the flag name used before feature level 224, when
// one flag covered both wildcard kinds and meant the channel-wide one.
func (f flagSet) hasStreamWildcard() bool {
	return f[FlagStreamWildcardMentioned] || f[FlagWildcardMentioned]
}
