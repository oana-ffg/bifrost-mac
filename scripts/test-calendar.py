#!/usr/bin/env python3
"""Drive the real compatibility CLI through a private, synthetic bridge."""
import datetime as dt
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading


def timestamp(value):
    return value.isoformat().replace("+00:00", "Z")


def instant(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def overlaps(event, start, end):
    first, last = instant(event["start"]), instant(event["end"])
    return first < end and (last > start or (first == last and first >= start))


def read_exact(connection, length):
    data = b""
    while len(data) < length:
        part = connection.recv(length - len(data))
        if not part:
            raise EOFError("Incomplete test bridge request")
        data += part
    return data


binary = str(Path(sys.argv[1]).resolve())
day = dt.timedelta(days=1)
today = dt.datetime.now(dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)


def event(identifier, start, end, all_day=False):
    return {"id": identifier, "calendar": "Synthetic", "title": identifier,
            "start": timestamp(start), "end": timestamp(end), "isAllDay": all_day,
            "availability": "busy", "recurring": True, "recurrence": "daily", "status": "confirmed"}


small = [event("spanning", today - day, today + 3 * day),
         event("all-day", today, today + day, True),
         event("point-today", today, today),
         event("point-tomorrow", today + day, today + day),
         event("exclusive-end", today + 2 * day, today + 2 * day)]
large = small + [event(f"occurrence-{index:05}", today + dt.timedelta(seconds=index * 16),
                       today + dt.timedelta(seconds=index * 16 + 60)) for index in range(9996)]
failures = []


def check(name, arguments, first, last, records, expected_queries):
    requests, errors = [], []
    with tempfile.TemporaryDirectory(prefix="bifrost-cli-", dir="/tmp") as directory:
        home = Path(directory)
        runtime = home / ".bifrost" / "run"
        runtime.mkdir(parents=True, mode=0o700)
        path = str(runtime / "bridge.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        os.chmod(path, 0o600)
        listener.listen(16)

        def serve():
            try:
                while True:
                    connection, _ = listener.accept()
                    with connection:
                        header = connection.recv(4)
                        if not header:  # Explicit shutdown connection, after the CLI exits.
                            return
                        header += read_exact(connection, 4 - len(header))
                        request = json.loads(read_exact(connection, struct.unpack("!I", header)[0]))
                        requests.append(request)
                        if request["method"] == "calendar.list":
                            result = {"calendars": [{"id": "synthetic", "name": "Synthetic"}]}
                        else:
                            assert request["method"] == "calendar.events", request
                            params = request["params"]
                            assert params["calendarIDs"] == ["synthetic"]
                            assert params["timezone"] in {"UTC", "GMT"}
                            result = {"events": sorted(
                                (row for row in records if overlaps(row, instant(params["start"]), instant(params["end"]))),
                                key=lambda row: (instant(row["start"]), row["id"]))}
                        payload = json.dumps({"version": 1, "ok": True, "result": result}).encode()
                        connection.sendall(struct.pack("!I", len(payload)) + payload)
            except Exception as error:
                errors.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        environment = dict(os.environ, HOME=directory, CFFIXED_USER_HOME=directory)
        try:
            run = subprocess.run([binary, "apple-calendar", "--timezone", "UTC", *arguments],
                                 env=environment, text=True, capture_output=True, timeout=60)
        finally:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as shutdown:
                shutdown.connect(path)
            worker.join(timeout=5)
            listener.close()
        assert not worker.is_alive(), "Test bridge did not stop"
        assert not errors, (errors, requests)
        assert run.returncode == 0, (run.returncode, run.stderr)
        assert not run.stderr, run.stderr
        output = json.loads(run.stdout)
        assert output["timezone"] in {"UTC", "GMT"}
        assert output["calendars"] == ["Synthetic"]
        assert output["range"]["start"] == first.date().isoformat()
        assert output["range"]["end"] == (last - day).date().isoformat()
        for label, start, end, rows in [("range", first, last, output["range"]["events"]),
                                        ("today", today, today + day, output["today"]),
                                        ("tomorrow", today + day, today + 2 * day, output["tomorrow"])]:
            expected = [{key: value for key, value in row.items() if key != "id"}
                        for row in sorted(records, key=lambda row: (instant(row["start"]), row["id"]))
                        if overlaps(row, start, end)]
            assert rows == expected, (name, label, len(rows), len(expected))
        queries = [request["params"] for request in requests if request["method"] == "calendar.events"]
        assert sum(request["method"] == "calendar.list" for request in requests) == 1
        print(f"{name}: {len(queries)} event queries, {len(output['range']['events'])} range rows", flush=True)
        if len(queries) != expected_queries:
            failures.append(f"{name}: expected {expected_queries} event queries, got {len(queries)}")


check("default 2-day range / 10000 occurrences", [], today, today + 2 * day, large, 1)
check("today only", ["--days", "1"], today, today + day, small, 2)
check("tomorrow only", ["--start", (today + day).date().isoformat(), "--days", "1"], today + day, today + 2 * day, small, 2)
check("unrelated historical range", ["--start", "2001-01-01", "--days", "2"],
      dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc), dt.datetime(2001, 1, 3, tzinfo=dt.timezone.utc), small, 3)
check("chunk boundary with spanning occurrence", ["--start", (today - 364 * day).date().isoformat(), "--days", "366"],
      today - 364 * day, today + 2 * day, small, 2)
check("maximum compatibility range", ["--days", "3660"], today, today + 3660 * day, small, 11)
if failures:
    raise SystemExit("\n".join(failures))
print("Compatibility output and bounded bridge request counts passed")
