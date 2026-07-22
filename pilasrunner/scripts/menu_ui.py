#!/usr/bin/env python3
"""Small PortMaster TTY menu with raw gamepad input support."""

import argparse
import errno
import glob
import os
import select
import struct
import sys
import time

try:
    import termios
    import tty as tty_module
except ImportError:
    termios = None
    tty_module = None


EV_KEY = 1
EV_ABS = 3
ABS_HAT0Y = 17
EVENT = struct.Struct("llHHi")

KEY_UP = {103, 544}
KEY_DOWN = {108, 545}
KEY_LAUNCH = {28, 57, 304, 305, 315, 316, 352}
KEY_BACK = {1}


def load_games(path):
    games = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            if "\t" in line:
                kind, name = line.split("\t", 1)
            else:
                kind, name = "apk", line
            games.append((kind, name))
    return games


def open_tty(preferred):
    paths = []
    if preferred:
        paths.append(preferred)
    paths.extend(["/dev/tty", "/dev/tty0", "/dev/tty1", "/dev/console"])

    seen = set()
    for path in paths:
        if not path or path in seen:
            continue
        seen.add(path)
        try:
            return os.open(path, os.O_RDWR | os.O_NONBLOCK), path
        except OSError:
            continue
    return None, ""


def write_tty(fd, text):
    if fd is None:
        return
    try:
        os.write(fd, text.encode("utf-8", "replace"))
    except OSError:
        pass


def set_raw(fd):
    if fd is None or termios is None or tty_module is None:
        return None
    try:
        old = termios.tcgetattr(fd)
        tty_module.setcbreak(fd)
        return old
    except Exception:
        return None


def restore_tty(fd, old):
    if fd is None or old is None or termios is None:
        return
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except Exception:
        pass


def render(fd, games, selected, runtime, loader):
    count = len(games)
    page_size = 10
    start = 0
    if count > page_size:
        start = selected - page_size // 2
        if start < 0:
            start = 0
        if start + page_size > count:
            start = count - page_size
    end = min(start + page_size, count)

    lines = [
        "\033[2J\033[H",
        "====================================================",
        " YoYo Pilas Runner",
        " Inspired by YoYo Loader Vita, powered by gmloader-next",
        "====================================================",
        "Games: {} | Runtime: {} | Loader: {}".format(count, runtime, loader),
        "",
    ]

    if start > 0:
        lines.append("    ...")

    for index in range(start, end):
        kind, name = games[index]
        if index == selected:
            lines.append("\033[7m > {:02d}  {:<34.34s}  [{}]\033[0m".format(index + 1, name, kind))
        else:
            lines.append("   {:02d}  {:<34.34s}  [{}]".format(index + 1, name, kind))

    if end < count:
        lines.append("    ...")

    lines.extend(
        [
            "",
            "D-Pad/Up/Down: Move   A/Start/Enter: Launch",
            "B/Select/Esc: Exit    Select + Start closes gameplay",
        ]
    )

    write_tty(fd, "\n".join(lines) + "\n")


def open_input_devices(known):
    devices = {}
    for path in sorted(glob.glob("/dev/input/event*")):
        if path in known:
            continue
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            known.add(path)
            continue
        devices[fd] = path
        known.add(path)
    return devices


def close_fd(fd):
    try:
        os.close(fd)
    except OSError:
        pass


def tty_action(data):
    if not data:
        return None
    if b"\x1b[A" in data:
        return "up"
    if b"\x1b[B" in data:
        return "down"
    if b"\r" in data or b"\n" in data or b" " in data:
        return "launch"
    lowered = data.lower()
    if b"w" in lowered or b"k" in lowered:
        return "up"
    if b"s" in lowered or b"j" in lowered:
        return "down"
    if b"a" in lowered or b"l" in lowered:
        return "launch"
    if b"b" in lowered or b"q" in lowered or data == b"\x1b":
        return "back"
    for byte in data:
        if 48 <= byte <= 57:
            return "number:{}".format(chr(byte))
    return None


def event_action(event_type, code, value):
    if event_type == EV_KEY:
        if value not in (1, 2):
            return None
        if code in KEY_UP:
            return "up"
        if code in KEY_DOWN:
            return "down"
        if code in KEY_LAUNCH:
            return "launch"
        if code in KEY_BACK:
            return "back"
    elif event_type == EV_ABS and code == ABS_HAT0Y:
        if value < 0:
            return "up"
        if value > 0:
            return "down"
    return None


def write_selection(path, selected):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("{}\n".format(selected))


def main():
    parser = argparse.ArgumentParser(description="YoYo Pilas Runner menu UI")
    parser.add_argument("--games", required=True)
    parser.add_argument("--selection", required=True)
    parser.add_argument("--runtime", default="unknown")
    parser.add_argument("--loader", default="next")
    parser.add_argument("--tty", default="")
    args = parser.parse_args()

    games = load_games(args.games)
    if not games:
        return 1

    tty_fd, tty_path = open_tty(args.tty)
    old_tty = set_raw(tty_fd)
    selected = 0
    known_paths = set()
    devices = {}
    next_rescan = 0.0
    last_render = 0.0

    try:
        while True:
            now = time.time()
            if now >= next_rescan:
                devices.update(open_input_devices(known_paths))
                next_rescan = now + 2.0

            if now - last_render > 0.05:
                render(tty_fd, games, selected, args.runtime, args.loader)
                last_render = now

            read_fds = list(devices.keys())
            if tty_fd is not None:
                read_fds.append(tty_fd)

            if not read_fds:
                print("No TTY or input devices were available for the menu.", file=sys.stderr)
                return 3

            try:
                readable, _, _ = select.select(read_fds, [], [], 0.25)
            except OSError:
                readable = []

            action = None
            for fd in readable:
                if fd == tty_fd:
                    try:
                        action = tty_action(os.read(fd, 32))
                    except OSError:
                        action = None
                else:
                    while True:
                        try:
                            data = os.read(fd, EVENT.size * 16)
                        except BlockingIOError:
                            break
                        except OSError as exc:
                            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                                close_fd(fd)
                                devices.pop(fd, None)
                            break

                        if not data:
                            close_fd(fd)
                            devices.pop(fd, None)
                            break

                        usable = len(data) - (len(data) % EVENT.size)
                        for offset in range(0, usable, EVENT.size):
                            _, _, event_type, code, value = EVENT.unpack_from(data, offset)
                            action = event_action(event_type, code, value)
                            if action:
                                break
                        if action:
                            break

                if action:
                    break

            if action == "up":
                selected = (selected - 1) % len(games)
            elif action == "down":
                selected = (selected + 1) % len(games)
            elif action == "launch":
                write_selection(args.selection, selected)
                return 0
            elif action == "back":
                return 2
            elif action and action.startswith("number:"):
                number = int(action.split(":", 1)[1])
                if number == 0:
                    return 2
                if 1 <= number <= len(games):
                    write_selection(args.selection, number - 1)
                    return 0
    finally:
        restore_tty(tty_fd, old_tty)
        if tty_fd is not None:
            close_fd(tty_fd)
        for fd in list(devices.keys()):
            close_fd(fd)


if __name__ == "__main__":
    raise SystemExit(main())
