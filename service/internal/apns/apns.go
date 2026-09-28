// Package apns sends push notifications to Apple's gateway.
//
// It is deliberately a thin seam over github.com/sideshow/apns2: that library is
// the only real Go option and has been dormant since 2024, so everything above
// this package talks to the Sender interface and never to apns2 itself.
package apns

import (
	"context"
	"encoding/json"
	"time"
)

// Notification is one push to one device token.
type Notification struct {
	Token       string
	Environment string
	// CollapseID gives the delivered notification a predictable identifier on
	// every device, which is what lets the app dismiss the same notification
	// elsewhere. Apple caps it at 64 bytes.
	CollapseID string
	Payload    Payload
}

// MaxCollapseIDBytes is Apple's limit for apns-collapse-id.
const MaxCollapseIDBytes = 64

// Payload is the JSON body. Custom keys are siblings of `aps`, never inside it:
// APNs ignores unknown keys within `aps`.
type Payload struct {
	Title             string
	Subtitle          string
	Body              string
	ThreadID          string
	Category          string
	Sound             string
	InterruptionLevel string
	MutableContent    bool
	Custom            map[string]any
}

func (p Payload) MarshalJSON() ([]byte, error) {
	alert := map[string]any{}
	if p.Title != "" {
		alert["title"] = p.Title
	}
	if p.Subtitle != "" {
		alert["subtitle"] = p.Subtitle
	}
	if p.Body != "" {
		alert["body"] = p.Body
	}

	aps := map[string]any{"alert": alert}
	if p.ThreadID != "" {
		aps["thread-id"] = p.ThreadID
	}
	if p.Category != "" {
		aps["category"] = p.Category
	}
	if p.Sound != "" {
		aps["sound"] = p.Sound
	}
	if p.InterruptionLevel != "" {
		aps["interruption-level"] = p.InterruptionLevel
	}
	if p.MutableContent {
		aps["mutable-content"] = 1
	}

	body := map[string]any{"aps": aps}
	for key, value := range p.Custom {
		body[key] = value
	}
	return json.Marshal(body)
}

// Receipt is what APNs answered.
type Receipt struct {
	Sent       bool
	StatusCode int
	Reason     string
	// Timestamp is set only on a 410 and is the moment APNs decided the token was
	// dead. A token re-registered after it is live again and must be kept.
	Timestamp time.Time
}

// Reasons this service acts on. The full table is in Apple's documentation.
const (
	ReasonUnregistered   = "Unregistered"
	ReasonBadDeviceToken = "BadDeviceToken"
	ReasonExpiredToken   = "ExpiredToken"
	// ReasonBadEnvironmentKeyInToken means the signing key is limited to the other
	// APNs environment, so no push to this token can ever succeed with it.
	ReasonBadEnvironmentKeyInToken = "BadEnvironmentKeyInToken"
)

// TokenIsDead reports whether APNs said this token will never work again.
// BadDeviceToken is excluded on purpose: it is also what a wrong environment or
// a wrong bundle id looks like, so deleting on it would wipe every token at once
// after a configuration mistake.
func (r Receipt) TokenIsDead() bool {
	return r.StatusCode == 410 && (r.Reason == ReasonUnregistered || r.Reason == ReasonExpiredToken)
}

// EnvironmentIsRefused reports a device the key cannot reach, typically a debug
// build's sandbox token left behind after installing a release build. The app
// registers again on every launch, so removing it is safe even after a key
// mistake.
func (r Receipt) EnvironmentIsRefused() bool {
	return r.StatusCode == 403 && r.Reason == ReasonBadEnvironmentKeyInToken
}

type Sender interface {
	Push(ctx context.Context, notification Notification) (Receipt, error)
}
