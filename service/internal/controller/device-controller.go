package controller

import (
	"errors"
	"net/http"
	"strings"

	"github.com/go-fuego/fuego"

	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/service"
)

const bearerPrefix = "Bearer "

// DeviceController exposes device registration over HTTP.
type DeviceController struct {
	devices *service.DeviceService
}

func NewDeviceController(devices *service.DeviceService) *DeviceController {
	return &DeviceController{devices: devices}
}

func (c *DeviceController) Register(ctx fuego.ContextWithBody[RegisterDeviceRequest]) (RegisterDeviceResponse, error) {
	body, err := ctx.Body()
	if err != nil {
		return RegisterDeviceResponse{}, err
	}

	output, err := c.devices.Register(ctx.Context(), service.RegisterInput{
		RealmURL:    body.RealmURL,
		Email:       body.Email,
		APIKey:      body.APIKey,
		DeviceToken: body.DeviceToken,
		Platform:    body.Platform,
		Environment: body.Environment,
		AppVersion:  body.AppVersion,
		// Optional here, unlike every other call: a first registration has no secret yet.
		PreviousDeviceSecret: strings.TrimPrefix(ctx.Header("Authorization"), bearerPrefix),
	})
	if err != nil {
		return RegisterDeviceResponse{}, httpError(err)
	}

	ctx.SetStatus(http.StatusCreated)
	return RegisterDeviceResponse{
		DeviceID:     output.DeviceID,
		DeviceSecret: output.DeviceSecret,
		ZulipUserID:  output.ZulipUserID,
		RealmURL:     body.RealmURL,
	}, nil
}

func (c *DeviceController) List(ctx fuego.ContextNoBody) (DeviceListResponse, error) {
	caller, err := c.authenticate(ctx)
	if err != nil {
		return DeviceListResponse{}, err
	}

	devices, err := c.devices.List(ctx.Context(), caller.User.ID)
	if err != nil {
		return DeviceListResponse{}, httpError(err)
	}

	response := DeviceListResponse{Devices: make([]DeviceResponse, 0, len(devices))}
	for _, device := range devices {
		response.Devices = append(response.Devices, deviceResponse(device, caller.Device.ID))
	}
	return response, nil
}

func (c *DeviceController) Deregister(ctx fuego.ContextNoBody) (DeregisterResponse, error) {
	caller, err := c.authenticate(ctx)
	if err != nil {
		return DeregisterResponse{}, err
	}

	if err := c.devices.Deregister(ctx.Context(), caller.User.ID, ctx.PathParam("deviceId")); err != nil {
		return DeregisterResponse{}, httpError(err)
	}
	return DeregisterResponse{Deregistered: true}, nil
}

func (c *DeviceController) Status(ctx fuego.ContextNoBody) (StatusResponse, error) {
	caller, err := c.authenticate(ctx)
	if err != nil {
		return StatusResponse{}, err
	}

	status, err := c.devices.Status(ctx.Context(), caller.User.ID)
	if err != nil {
		return StatusResponse{}, httpError(err)
	}
	return StatusResponse{
		RealmURL:       status.User.RealmURL,
		ZulipUserID:    status.User.ZulipUserID,
		AccountStatus:  string(status.User.Status),
		StatusDetail:   status.User.StatusDetail,
		Devices:        status.Devices,
		QueueConnected: status.Health.Connected,
		Parked:         status.Health.Parked,
		ParkedUntil:    status.Health.ParkedUntil,
		LastEventAt:    status.Health.LastEventAt,
		LastError:      status.Health.LastError,
	}, nil
}

func (c *DeviceController) SendTest(ctx fuego.ContextNoBody) (TestNotificationResponse, error) {
	caller, err := c.authenticate(ctx)
	if err != nil {
		return TestNotificationResponse{}, err
	}

	receipt, err := c.devices.SendTest(ctx.Context(), caller)
	if err != nil {
		return TestNotificationResponse{}, httpError(err)
	}
	return TestNotificationResponse{
		Sent:       receipt.Sent,
		StatusCode: receipt.StatusCode,
		Reason:     receipt.Reason,
	}, nil
}

func (c *DeviceController) authenticate(ctx fuego.ContextNoBody) (service.Caller, error) {
	header := ctx.Header("Authorization")
	if !strings.HasPrefix(header, bearerPrefix) {
		return service.Caller{}, fuego.UnauthorizedError{
			Title:  "Unauthorized",
			Detail: "Send the device secret as a bearer token.",
		}
	}

	caller, err := c.devices.Authenticate(ctx.Context(), strings.TrimPrefix(header, bearerPrefix))
	if err != nil {
		return service.Caller{}, httpError(err)
	}
	return caller, nil
}

func deviceResponse(device domain.Device, currentDeviceID string) DeviceResponse {
	return DeviceResponse{
		DeviceID:     device.ID,
		Platform:     device.Platform,
		Environment:  device.Environment,
		AppVersion:   device.AppVersion,
		RegisteredAt: device.RegisteredAt,
		LastSeenAt:   device.LastSeenAt,
		Current:      device.ID == currentDeviceID,
	}
}

// httpError maps the service's error vocabulary onto status codes. Anything
// unrecognised stays a 500 and its text never reaches the client.
func httpError(err error) error {
	switch {
	case errors.Is(err, service.ErrInvalidInput):
		return fuego.BadRequestError{Title: "Invalid request", Detail: err.Error(), Err: err}
	case errors.Is(err, service.ErrCredentialsRejected):
		return fuego.UnauthorizedError{
			Title:  "Zulip rejected the credentials",
			Detail: "The Zulip server did not accept that email and API key.",
			Err:    err,
		}
	case errors.Is(err, service.ErrUnauthenticated):
		return fuego.UnauthorizedError{
			Title:  "Unauthorized",
			Detail: "That device secret is not registered. Register the device again.",
			Err:    err,
		}
	case errors.Is(err, service.ErrNotFound):
		return fuego.NotFoundError{Title: "Not found", Err: err}
	default:
		return err
	}
}
