#!/usr/bin/env python3
"""Watch Linux input events and force-close a game on Select + Start."""

import argparse
import errno
import glob
import os
import select
import signal
import struct
import time


EV_KEY = 1
DEFAULT_SELECT_CODES = {1, 139, 158, 174, 314, 353, 704}
DEFAULT_START_CODES = {28, 172, 315, 316, 352, 705}
EVENT = struct.Struct("llHHi")
COMBO_WINDOW_SECONDS = 0.75


def timestamp():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def append_log(path, message):
    line = "[{}] [HOTKEY] {}\n".format(timestamp(), message)
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line)
    except Exception:
        pass


def parse_codes(value, fallback):
    if not value:
        return set(fallback)

    codes = set()
    for part in value.replace(",", " ").split():
        try:
            codes.add(int(part, 0))
        except ValueError:
            continue

    return codes or set(fallback)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError as exc:
        return exc.errno == errno.EPERM


def write_flag(path):
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("select_start\n")
            handle.write("{}\n".format(timestamp()))
    except Exception:
        pass


def force_quit(pid, flag_path, log_path, grace):
    write_flag(flag_path)
    append_log(log_path, "Select + Start detected. Sending TERM to pid {}.".format(pid))

    try:
        if os.getpgid(pid) == pid:
            os.kill(-pid, signal.SIGTERM)
            append_log(log_path, "Sent TERM to process group {}.".format(pid))
    except OSError as exc:
        append_log(log_path, "Group TERM failed for pgid {}: {}".format(pid, exc))

    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as exc:
        append_log(log_path, "TERM failed for pid {}: {}".format(pid, exc))

    deadline = time.time() + max(grace, 0.0)
    while time.time() < deadline:
        if not pid_alive(pid):
            append_log(log_path, "Target pid {} exited after TERM.".format(pid))
            return
        time.sleep(0.05)

    if pid_alive(pid):
        try:
            if os.getpgid(pid) == pid:
                os.kill(-pid, signal.SIGKILL)
                append_log(log_path, "Sent KILL to process group {}.".format(pid))
        except OSError as exc:
            append_log(log_path, "Group KILL failed for pgid {}: {}".format(pid, exc))
        try:
            os.kill(pid, signal.SIGKILL)
            append_log(log_path, "Target pid {} was still alive. Sent KILL.".format(pid))
        except OSError as exc:
            append_log(log_path, "KILL failed for pid {}: {}".format(pid, exc))


def open_input_devices(log_path, known):
    devices = {}
    for path in sorted(glob.glob("/dev/input/event*")):
        if path in known:
            continue
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            append_log(log_path, "Could not open {}: {}".format(path, exc))
            known.add(path)
            continue

        devices[fd] = path
        known.add(path)
        append_log(log_path, "Watching input device {}.".format(path))
    return devices


def close_fd(fd):
    try:
        os.close(fd)
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser(description="YoYo Pilas Runner hotkey watcher")
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--flag", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--grace", type=float, default=1.0)
    args = parser.parse_args()

    select_codes = parse_codes(os.environ.get("PILASRUNNER_HOTKEY_SELECT_CODES"), DEFAULT_SELECT_CODES)
    start_codes = parse_codes(os.environ.get("PILASRUNNER_HOTKEY_START_CODES"), DEFAULT_START_CODES)
    pressed = set()
    last_select_press = 0.0
    last_start_press = 0.0
    known_paths = set()
    devices = {}
    next_rescan = 0.0
    arm_at = time.monotonic() + float(os.environ.get("PILASRUNNER_HOTKEY_ARM_DELAY", "1.0") or "1.0")
    armed = False
    debug_budget = int(os.environ.get("PILASRUNNER_HOTKEY_DEBUG_EVENTS", "80") or "0")

    append_log(
        args.log,
        "Watcher started for pid {}. select_codes={} start_codes={} event_size={}. Arming after launch input is released.".format(
            args.pid,
            sorted(select_codes),
            sorted(start_codes),
            EVENT.size,
        ),
    )

    try:
        while pid_alive(args.pid):
            now = time.time()
            mono_now = time.monotonic()
            if not armed and mono_now >= arm_at and not pressed.intersection(select_codes) and not pressed.intersection(start_codes):
                armed = True
                last_select_press = 0.0
                last_start_press = 0.0
                append_log(args.log, "Watcher armed for pid {}.".format(args.pid))

            if now >= next_rescan:
                devices.update(open_input_devices(args.log, known_paths))
                next_rescan = now + 2.0

            if not devices:
                time.sleep(0.25)
                continue

            try:
                readable, _, _ = select.select(list(devices.keys()), [], [], 0.25)
            except OSError:
                readable = []

            for fd in readable:
                while True:
                    try:
                        data = os.read(fd, EVENT.size * 16)
                    except BlockingIOError:
                        break
                    except OSError as exc:
                        append_log(args.log, "Stopped watching {}: {}".format(devices.get(fd, fd), exc))
                        close_fd(fd)
                        devices.pop(fd, None)
                        break

                    if not data:
                        append_log(args.log, "Input device {} closed.".format(devices.get(fd, fd)))
                        close_fd(fd)
                        devices.pop(fd, None)
                        break

                    usable = len(data) - (len(data) % EVENT.size)
                    for offset in range(0, usable, EVENT.size):
                        _, _, event_type, code, value = EVENT.unpack_from(data, offset)
                        if event_type != EV_KEY:
                            continue
                        if debug_budget > 0 and value in (0, 1, 2):
                            append_log(args.log, "EV_KEY device={} code={} value={}".format(devices.get(fd, fd), code, value))
                            debug_budget -= 1
                        if value in (1, 2):
                            pressed.add(code)
                            now = time.time()
                            if code in select_codes:
                                last_select_press = now
                            if code in start_codes:
                                last_start_press = now
                        elif value == 0:
                            pressed.discard(code)

                        if not armed:
                            if time.monotonic() >= arm_at and not pressed.intersection(select_codes) and not pressed.intersection(start_codes):
                                armed = True
                                last_select_press = 0.0
                                last_start_press = 0.0
                                append_log(args.log, "Watcher armed for pid {}.".format(args.pid))
                            else:
                                last_select_press = 0.0
                                last_start_press = 0.0
                                continue

                        held_combo = pressed.intersection(select_codes) and pressed.intersection(start_codes)
                        timed_combo = last_select_press > 0 and last_start_press > 0 and abs(last_select_press - last_start_press) <= COMBO_WINDOW_SECONDS
                        if held_combo or timed_combo:
                            force_quit(args.pid, args.flag, args.log, args.grace)
                            return 0
    finally:
        for fd in list(devices.keys()):
            close_fd(fd)

    append_log(args.log, "Target pid {} is no longer alive. Watcher exiting.".format(args.pid))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
