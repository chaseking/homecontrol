class ProviderError(Exception):
    """A whole integration is unavailable (bad config, bridge down, no credentials)."""


class DeviceError(Exception):
    """A single device command failed."""

    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status
