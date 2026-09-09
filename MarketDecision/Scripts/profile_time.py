"""Provisioning plist dates without tzinfo are UTC, not local wall time."""
import datetime


def as_utc(value):
    if not isinstance(value, datetime.datetime):
        raise ValueError('Invalid profile expiration date')
    if value.tzinfo is None:
        return value.replace(tzinfo=datetime.timezone.utc)
    return value.astimezone(datetime.timezone.utc)


def require_unexpired(expiration, now=None):
    current = datetime.datetime.now(datetime.timezone.utc) if now is None else as_utc(now)
    if as_utc(expiration) <= current:
        raise ValueError('Profile expired')
