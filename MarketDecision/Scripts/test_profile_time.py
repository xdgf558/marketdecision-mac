import datetime as dt
import unittest
from profile_time import require_unexpired


class ExpirationTests(unittest.TestCase):
    now = dt.datetime(2026, 9, 9, 12, tzinfo=dt.timezone.utc)

    def test_naive_plist_date_is_utc(self):
        require_unexpired(dt.datetime(2026, 9, 9, 12, 0, 1), self.now)

    def test_offsets_describe_same_instant(self):
        for hours in [-7, 0, 8]:
            local = self.now.astimezone(dt.timezone(dt.timedelta(hours=hours)))
            with self.assertRaises(ValueError):
                require_unexpired(local, self.now)
            require_unexpired(local + dt.timedelta(seconds=1), self.now)

    def test_expired_and_exact_boundary_rejected(self):
        for value in [self.now, self.now - dt.timedelta(microseconds=1), self.now.replace(tzinfo=None)]:
            with self.assertRaises(ValueError):
                require_unexpired(value, self.now)

    def test_missing_or_invalid_date_rejected(self):
        for value in [None, '2026-09-09', 1]:
            with self.assertRaises(ValueError):
                require_unexpired(value, self.now)


if __name__ == '__main__':
    unittest.main()
