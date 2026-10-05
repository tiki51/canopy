"""Retry gateway calls with capped exponential backoff."""

BASE_DELAYS = (0.5, 2.0, 8.0)  # seconds


def with_backoff(call, invoice, *, key):
    for base in BASE_DELAYS:
        try:
            return call(invoice, idempotency_key=key)
        except TimeoutError:
            continue
    raise TimeoutError("gave up")
