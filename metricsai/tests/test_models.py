"""Tests for the metrics payload models."""

from __future__ import annotations

from datetime import UTC, date, datetime

import pytest

from metricsai.models import MetricRow, default_week_ending, week_window, weekday_number


def test_default_week_ending_returns_thursday() -> None:
    # 2026-06-10 is a Wednesday; the prior Thursday is 2026-06-04.
    assert default_week_ending(date(2026, 6, 10)) == date(2026, 6, 4)


def test_default_week_ending_on_thursday_is_same_day() -> None:
    # 2026-06-04 is a Thursday.
    assert default_week_ending(date(2026, 6, 4)) == date(2026, 6, 4)


def test_default_week_ending_configurable_weekday() -> None:
    # 2026-06-10 is a Wednesday; with a Sunday-ending week the prior Sunday is 2026-06-07.
    assert default_week_ending(date(2026, 6, 10), weekday=6) == date(2026, 6, 7)


def test_weekday_number_accepts_names_and_abbreviations() -> None:
    assert weekday_number("thursday") == 3
    assert weekday_number("THU") == 3
    assert weekday_number(" monday ") == 0
    with pytest.raises(ValueError, match="Invalid weekday"):
        weekday_number("funday")


def test_payload_is_flat_with_date_key() -> None:
    row = MetricRow(week_ending_date=date(2026, 6, 7), metrics={"security_critical": 0})
    assert row.to_payload() == {"week_ending_date": "2026-06-07", "security_critical": 0}


def test_week_window_is_seven_inclusive_utc_days() -> None:
    start, end = week_window(date(2026, 6, 7))
    assert start == datetime(2026, 6, 1, 0, 0, 0, tzinfo=UTC)
    assert end == datetime(2026, 6, 7, 23, 59, 59, tzinfo=UTC)
