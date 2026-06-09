"""Pydantic models for the metrics payload."""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from typing import Any

from pydantic import BaseModel, Field

#: A single metric value. Keys map to columns in the destination spreadsheet.
MetricValue = int | float | str | bool


# Weekday names -> Python weekday() index (Monday=0 .. Sunday=6).
WEEKDAYS = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}

#: Default day on which the reporting week closes (window: that day back through 6 days
#: earlier, i.e. Fri 00:00:00Z .. Thu 23:59:59Z for the default).
DEFAULT_WEEK_ENDING_WEEKDAY = WEEKDAYS["thursday"]


def weekday_number(name: str) -> int:
    """Convert a weekday name to its :meth:`date.weekday` index.

    :param name: Full or three-letter weekday name, case-insensitive (e.g. ``"thursday"``
        or ``"thu"``).
    :returns: The weekday index (Monday=0 .. Sunday=6).
    :raises ValueError: If ``name`` is not a recognised weekday.
    """
    key = name.strip().lower()
    for full, number in WEEKDAYS.items():
        if key in (full, full[:3]):
            return number
    raise ValueError(f"Invalid weekday {name!r}; use e.g. 'thursday' or 'thu'.")


def default_week_ending(
    today: date | None = None, *, weekday: int = DEFAULT_WEEK_ENDING_WEEKDAY
) -> date:
    """Return the most recent date falling on ``weekday`` (the week-ending day).

    The spreadsheet keys each row by the day that closes the reporting week. If ``today``
    is already that weekday it is returned unchanged.

    :param today: Reference date (defaults to the current UTC date); aids testing.
    :param weekday: Week-ending weekday index (Monday=0 .. Sunday=6).
    :returns: The week-ending date on or before ``today``.
    """
    today = today or datetime.now(UTC).date()
    return today - timedelta(days=(today.weekday() - weekday) % 7)


def week_window(week_ending: date) -> tuple[datetime, datetime]:
    """Return the inclusive UTC ``(start, end)`` of the 7 days ending on ``week_ending``.

    :param week_ending: The day that closes the reporting week.
    :returns: ``(start, end)`` where ``start`` is 00:00:00Z six days earlier and ``end`` is
        23:59:59Z on ``week_ending``.
    """
    start = datetime.combine(week_ending - timedelta(days=6), time.min, tzinfo=UTC)
    end = datetime.combine(week_ending, time(23, 59, 59), tzinfo=UTC)
    return start, end


class MetricRow(BaseModel):
    """One week's row of metrics destined for the spreadsheet.

    :ivar week_ending_date: The Thursday that closes the reporting week; the row's key column.
    :ivar metrics: Mapping of spreadsheet field name to value, merged from every module.
    """

    week_ending_date: date = Field(default_factory=default_week_ending)
    metrics: dict[str, MetricValue] = Field(default_factory=dict)

    def to_payload(self) -> dict[str, Any]:
        """Flatten to the single JSON object posted to the webhook.

        ``week_ending_date`` is serialised as an ISO-8601 date (``YYYY-MM-DD``) and the
        metric keys are spread alongside it, yielding one flat row whose keys are exactly
        the spreadsheet columns.

        :returns: The flattened, JSON-serialisable payload.
        """
        return {"week_ending_date": self.week_ending_date.isoformat(), **self.metrics}
