#!/usr/bin/env python3
"""Framebuffer game-selection UI for YoYo Pilas Runner."""

import argparse
import errno
import glob
import mmap
import os
import select
import struct
import sys
import time

try:
    import fcntl
except ImportError:
    fcntl = None


FBIOGET_VSCREENINFO = 0x4600
EV_KEY = 1
EV_ABS = 3
ABS_HAT0Y = 17
EVENT = struct.Struct("llHHi")

KEY_UP = {103, 544}
KEY_DOWN = {108, 545}
KEY_LAUNCH = {28, 57, 304, 305, 315, 316, 352}
KEY_BACK = {1}

INK = (245, 255, 233)
MUTED = (156, 181, 156)
BG = (7, 16, 8)
PANEL = (13, 26, 18)
PANEL_STRONG = (20, 43, 28)
LIME = (216, 255, 41)
GREEN = (52, 211, 55)
CYAN = (88, 230, 255)
AMBER = (255, 202, 92)
DARK = (4, 12, 7)


FONT = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01111", "10000", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "J": ["00111", "00010", "00010", "00010", "10010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "11100"],
    " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    "_": ["00000", "00000", "00000", "00000", "00000", "00000", "11111"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
    "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
    "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
    "[": ["01110", "01000", "01000", "01000", "01000", "01000", "01110"],
    "]": ["01110", "00010", "00010", "00010", "00010", "00010", "01110"],
}


def timestamp():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def log(path, message):
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("[{}] [VISUAL_UI] {}\n".format(timestamp(), message))
    except Exception:
        pass


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
            games.append({"kind": kind.upper(), "name": name})
    return games


def read_ppm(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, "rb") as handle:
        if handle.readline().strip() != b"P6":
            return None
        tokens = []
        while len(tokens) < 3:
            line = handle.readline()
            if not line:
                return None
            if line.startswith(b"#"):
                continue
            tokens.extend(line.split())
        width, height, max_value = [int(item) for item in tokens[:3]]
        if max_value != 255:
            return None
        data = handle.read(width * height * 3)
    if len(data) != width * height * 3:
        return None
    return width, height, data


class Framebuffer:
    def __init__(self, path, log_path):
        if fcntl is None:
            raise RuntimeError("fcntl is unavailable")
        self.path = path
        self.log_path = log_path
        self.fd = os.open(path, os.O_RDWR)
        vinfo = bytearray(160)
        fcntl.ioctl(self.fd, FBIOGET_VSCREENINFO, vinfo, True)
        values = struct.unpack_from("IIIIIIII", vinfo, 0)
        self.width = values[0]
        self.height = values[1]
        self.virtual_width = values[2] or self.width
        self.virtual_height = values[3] or self.height
        self.bpp = values[6]
        self.red = struct.unpack_from("III", vinfo, 32)
        self.green = struct.unpack_from("III", vinfo, 44)
        self.blue = struct.unpack_from("III", vinfo, 56)
        self.transp = struct.unpack_from("III", vinfo, 68)
        if self.width <= 0 or self.height <= 0:
            raise RuntimeError("invalid framebuffer dimensions")
        if self.bpp not in (16, 24, 32):
            raise RuntimeError("unsupported framebuffer depth {}".format(self.bpp))
        self.bytes_per_pixel = self.bpp // 8
        self.line_length = self.virtual_width * self.bytes_per_pixel
        self.size = self.line_length * self.virtual_height
        self.mem = mmap.mmap(self.fd, self.size, mmap.MAP_SHARED, mmap.PROT_WRITE)
        self.rgb = bytearray(self.width * self.height * 3)
        log(log_path, "Opened {}: {}x{} {}bpp.".format(path, self.width, self.height, self.bpp))

    def close(self):
        try:
            self.mem.close()
        except Exception:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass

    def fill(self, color):
        r, g, b = color
        self.rgb[:] = bytes((r, g, b)) * (self.width * self.height)

    def rect(self, x, y, w, h, color):
        x = max(0, min(self.width, int(x)))
        y = max(0, min(self.height, int(y)))
        w = max(0, min(self.width - x, int(w)))
        h = max(0, min(self.height - y, int(h)))
        if w <= 0 or h <= 0:
            return
        r, g, b = color
        row = bytes((r, g, b)) * w
        stride = self.width * 3
        for yy in range(y, y + h):
            start = yy * stride + x * 3
            self.rgb[start:start + w * 3] = row

    def outline(self, x, y, w, h, color, thickness=2):
        self.rect(x, y, w, thickness, color)
        self.rect(x, y + h - thickness, w, thickness, color)
        self.rect(x, y, thickness, h, color)
        self.rect(x + w - thickness, y, thickness, h, color)

    def text(self, x, y, text, color=INK, scale=2, max_width=None):
        cursor = int(x)
        limit = None if max_width is None else int(x + max_width)
        text = str(text).upper()
        for char in text:
            glyph = FONT.get(char, FONT.get(" "))
            glyph_width = 5 * scale
            if limit is not None and cursor + glyph_width > limit:
                break
            for row_index, row in enumerate(glyph):
                for col_index, value in enumerate(row):
                    if value == "1":
                        self.rect(cursor + col_index * scale, y + row_index * scale, scale, scale, color)
            cursor += 6 * scale
        return cursor

    def blit_ppm(self, x, y, image, scale=1):
        if not image:
            return
        width, height, data = image
        x = int(x)
        y = int(y)
        scale = max(1, int(scale))
        for yy in range(height):
            for xx in range(width):
                src = (yy * width + xx) * 3
                color = data[src:src + 3]
                if color == b"\x06\x11\x0a":
                    continue
                self.rect(x + xx * scale, y + yy * scale, scale, scale, tuple(color))

    def _pack_pixel(self, r, g, b):
        if self.bpp == 16:
            red = (r >> (8 - self.red[1])) << self.red[0] if self.red[1] else (r >> 3) << 11
            green = (g >> (8 - self.green[1])) << self.green[0] if self.green[1] else (g >> 2) << 5
            blue = (b >> (8 - self.blue[1])) << self.blue[0] if self.blue[1] else (b >> 3)
            return int(red | green | blue).to_bytes(2, "little")
        if self.bpp == 24:
            return bytes((b, g, r))
        red = (r >> (8 - self.red[1])) << self.red[0] if self.red[1] else r << 16
        green = (g >> (8 - self.green[1])) << self.green[0] if self.green[1] else g << 8
        blue = (b >> (8 - self.blue[1])) << self.blue[0] if self.blue[1] else b
        alpha = (255 >> (8 - self.transp[1])) << self.transp[0] if self.transp[1] else 0
        return int(red | green | blue | alpha).to_bytes(4, "little")

    def present(self):
        packed = bytearray(self.line_length * self.height)
        src_stride = self.width * 3
        for y in range(self.height):
            dst = y * self.line_length
            src = y * src_stride
            for x in range(self.width):
                r = self.rgb[src]
                g = self.rgb[src + 1]
                b = self.rgb[src + 2]
                packed[dst:dst + self.bytes_per_pixel] = self._pack_pixel(r, g, b)
                src += 3
                dst += self.bytes_per_pixel
        self.mem.seek(0)
        self.mem.write(packed)


def clamp(value, lo, hi):
    return max(lo, min(hi, value))


def fit(value, axis_scale):
    return int(value * axis_scale)


def render(fb, games, selected, runtime, loader, logo):
    w, h = fb.width, fb.height
    sx, sy = w / 1280.0, h / 720.0
    s = max(1, int(min(sx, sy) * 2.7))
    small = max(1, int(min(sx, sy) * 1.9))
    tiny = max(1, int(min(sx, sy) * 1.55))
    count = len(games)

    fb.fill(BG)
    fb.rect(0, 0, w, h, (10, 18, 13))
    fb.rect(0, 0, w, fit(120, sy), (15, 38, 19))
    fb.outline(fit(14, sx), fit(14, sy), w - fit(28, sx), h - fit(28, sy), (66, 88, 34), max(1, fit(2, sx)))

    top_x, top_y = fit(26, sx), fit(24, sy)
    top_w, top_h = w - fit(52, sx), fit(104, sy)
    fb.rect(top_x, top_y, top_w, top_h, (6, 17, 10))
    fb.outline(top_x, top_y, top_w, top_h, (64, 90, 31), 2)
    if logo:
        logo_scale = max(1, min(max(1, (top_h - 14) // logo[1]), max(1, fit(340, sx) // logo[0])))
        fb.blit_ppm(top_x + fit(14, sx), top_y + fit(4, sy), logo, logo_scale)
    fb.text(top_x + fit(190, sx), top_y + fit(28, sy), "YOYO PILAS RUNNER", LIME, s, fit(620, sx))
    fb.text(top_x + fit(190, sx), top_y + fit(66, sy), "INSPIRED BY YOYO LOADER VITA", MUTED, tiny, fit(620, sx))
    fb.text(top_x + top_w - fit(252, sx), top_y + fit(34, sy), time.strftime("%H:%M"), CYAN, small)
    fb.text(top_x + top_w - fit(156, sx), top_y + fit(34, sy), "PORTMASTER", MUTED, tiny)

    left_x, left_y = fit(26, sx), fit(146, sy)
    left_w, left_h = fit(430, sx), h - left_y - fit(32, sy)
    right_x, right_y = left_x + left_w + fit(16, sx), left_y
    right_w, right_h = w - right_x - fit(26, sx), left_h
    fb.rect(left_x, left_y, left_w, left_h, PANEL)
    fb.outline(left_x, left_y, left_w, left_h, (52, 88, 35), 2)
    fb.rect(right_x, right_y, right_w, right_h, PANEL)
    fb.outline(right_x, right_y, right_w, right_h, (52, 88, 35), 2)

    fb.rect(left_x + fit(12, sx), left_y + fit(12, sy), left_w - fit(24, sx), fit(44, sy), PANEL_STRONG)
    fb.text(left_x + fit(24, sx), left_y + fit(24, sy), "ALL", DARK, small)
    fb.rect(left_x + fit(96, sx), left_y + fit(12, sy), fit(96, sx), fit(44, sy), (36, 50, 30))
    fb.text(left_x + fit(112, sx), left_y + fit(24, sy), "READY", MUTED, tiny)
    fb.rect(left_x + fit(204, sx), left_y + fit(12, sy), fit(136, sx), fit(44, sy), (36, 50, 30))
    fb.text(left_x + fit(218, sx), left_y + fit(24, sy), "PROFILES", MUTED, tiny)

    page_size = max(4, (left_h - fit(84, sy)) // fit(72, sy))
    start = clamp(selected - page_size // 2, 0, max(0, count - page_size))
    end = min(count, start + page_size)
    row_y = left_y + fit(70, sy)
    for index in range(start, end):
        game = games[index]
        selected_row = index == selected
        row_h = fit(62, sy)
        if selected_row:
            fb.rect(left_x + fit(12, sx), row_y, left_w - fit(24, sx), row_h, (47, 70, 24))
            fb.outline(left_x + fit(12, sx), row_y, left_w - fit(24, sx), row_h, LIME, 2)
        else:
            fb.rect(left_x + fit(12, sx), row_y, left_w - fit(24, sx), row_h, (9, 20, 13))
        tile_x, tile_y = left_x + fit(24, sx), row_y + fit(9, sy)
        fb.rect(tile_x, tile_y, fit(44, sx), fit(44, sy), LIME if selected_row else GREEN)
        fb.text(tile_x + fit(13, sx), tile_y + fit(11, sy), game["name"][:1], DARK, small)
        fb.text(left_x + fit(82, sx), row_y + fit(12, sy), game["name"], INK, tiny, left_w - fit(178, sx))
        fb.text(left_x + fit(82, sx), row_y + fit(38, sy), "{} / {}".format(runtime, game["kind"]), MUTED, 1 if tiny > 1 else tiny, left_w - fit(178, sx))
        fb.text(left_x + left_w - fit(86, sx), row_y + fit(23, sy), "APK", CYAN, 1 if tiny > 1 else tiny)
        row_y += row_h + fit(8, sy)

    game = games[selected]
    stage_x, stage_y = right_x + fit(16, sx), right_y + fit(16, sy)
    stage_w, stage_h = right_w - fit(32, sx), fit(202, sy)
    fb.rect(stage_x, stage_y, stage_w, stage_h, (3, 11, 7))
    fb.outline(stage_x, stage_y, stage_w, stage_h, (64, 90, 31), 2)
    fb.rect(stage_x + fit(18, sx), stage_y + fit(94, sy), fit(92, sx), fit(92, sy), LIME)
    fb.text(stage_x + fit(45, sx), stage_y + fit(122, sy), game["name"][:1], DARK, max(2, s + 1))
    fb.text(stage_x + fit(130, sx), stage_y + fit(52, sy), game["name"], INK, max(2, s), stage_w - fit(160, sx))
    fb.text(stage_x + fit(130, sx), stage_y + fit(102, sy), "GMLOADER-NEXT / {}".format(loader.upper()), MUTED, tiny, stage_w - fit(160, sx))

    stats_y = stage_y + stage_h + fit(18, sy)
    stat_w = (stage_w - fit(24, sx)) // 3
    stats = [("ARCH", runtime.upper()), ("SAVE", "READY"), ("CONTROLS", "MAPPED")]
    for idx, (label, value) in enumerate(stats):
        box_x = stage_x + idx * (stat_w + fit(12, sx))
        fb.rect(box_x, stats_y, stat_w, fit(74, sy), (7, 23, 18))
        fb.outline(box_x, stats_y, stat_w, fit(74, sy), (28, 66, 52), 2)
        fb.text(box_x + fit(14, sx), stats_y + fit(14, sy), label, MUTED, tiny)
        fb.text(box_x + fit(14, sx), stats_y + fit(42, sy), value, CYAN if idx == 0 else LIME, tiny, stat_w - fit(26, sx))

    action_y = stats_y + fit(92, sy)
    fb.rect(stage_x, action_y, fit(220, sx), fit(54, sy), LIME)
    fb.text(stage_x + fit(44, sx), action_y + fit(18, sy), "LAUNCH", DARK, small)
    fb.rect(stage_x + fit(236, sx), action_y, fit(104, sx), fit(54, sy), (7, 23, 18))
    fb.outline(stage_x + fit(236, sx), action_y, fit(104, sx), fit(54, sy), (28, 66, 52), 2)
    fb.text(stage_x + fit(260, sx), action_y + fit(18, sy), "SCAN", CYAN, tiny)
    fb.rect(stage_x + fit(354, sx), action_y, fit(130, sx), fit(54, sy), (7, 23, 18))
    fb.outline(stage_x + fit(354, sx), action_y, fit(130, sx), fit(54, sy), (28, 66, 52), 2)
    fb.text(stage_x + fit(376, sx), action_y + fit(18, sy), "CONFIG", CYAN, tiny)

    activity_y = action_y + fit(76, sy)
    fb.rect(stage_x, activity_y, stage_w, fit(112, sy), (9, 20, 13))
    fb.outline(stage_x, activity_y, stage_w, fit(112, sy), (52, 88, 35), 2)
    fb.text(stage_x + fit(18, sx), activity_y + fit(18, sy), "READY", LIME, small)
    fb.text(stage_x + fit(18, sx), activity_y + fit(54, sy), "A/START LAUNCHES  DPAD MOVES  SELECT+START CLOSES GAMEPLAY", MUTED, tiny, stage_w - fit(36, sx))
    fb.rect(stage_x + fit(18, sx), activity_y + fit(88, sy), stage_w - fit(36, sx), fit(8, sy), (20, 42, 30))
    fb.rect(stage_x + fit(18, sx), activity_y + fit(88, sy), int((stage_w - fit(36, sx)) * 0.34), fit(8, sy), LIME)
    fb.present()


def open_input_devices(known, log_path):
    devices = {}
    for path in sorted(glob.glob("/dev/input/event*")):
        if path in known:
            continue
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            known.add(path)
            log(log_path, "Could not open {}: {}".format(path, exc))
            continue
        devices[fd] = path
        known.add(path)
        log(log_path, "Watching input device {}.".format(path))
    return devices


def close_fd(fd):
    try:
        os.close(fd)
    except OSError:
        pass


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
    if event_type == EV_ABS and code == ABS_HAT0Y:
        if value < 0:
            return "up"
        if value > 0:
            return "down"
    return None


def write_selection(path, selected):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("{}\n".format(selected))


def main():
    parser = argparse.ArgumentParser(description="YoYo Pilas Runner framebuffer UI")
    parser.add_argument("--games", required=True)
    parser.add_argument("--selection", required=True)
    parser.add_argument("--runtime", default="unknown")
    parser.add_argument("--loader", default="next")
    parser.add_argument("--logo", default="")
    parser.add_argument("--log", default="")
    parser.add_argument("--fb", default=os.environ.get("PILASRUNNER_FB", "/dev/fb0"))
    args = parser.parse_args()

    games = load_games(args.games)
    if not games:
        return 1

    try:
        fb = Framebuffer(args.fb, args.log)
    except Exception as exc:
        log(args.log, "Framebuffer UI unavailable: {}".format(exc))
        return 3

    logo = read_ppm(args.logo)
    known_paths = set()
    devices = {}
    selected = 0
    next_rescan = 0.0

    try:
        render(fb, games, selected, args.runtime, args.loader, logo)
        while True:
            now = time.time()
            if now >= next_rescan:
                devices.update(open_input_devices(known_paths, args.log))
                next_rescan = now + 2.0

            if not devices:
                time.sleep(0.2)
                continue

            try:
                readable, _, _ = select.select(list(devices.keys()), [], [], 0.25)
            except OSError:
                readable = []

            action = None
            for fd in readable:
                while True:
                    try:
                        data = os.read(fd, EVENT.size * 16)
                    except BlockingIOError:
                        break
                    except OSError as exc:
                        if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                            log(args.log, "Stopped watching {}: {}".format(devices.get(fd, fd), exc))
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
                            log(args.log, "Input action={} type={} code={} value={}.".format(action, event_type, code, value))
                            break
                    if action:
                        break
                if action:
                    break

            if action == "up":
                selected = (selected - 1) % len(games)
                render(fb, games, selected, args.runtime, args.loader, logo)
            elif action == "down":
                selected = (selected + 1) % len(games)
                render(fb, games, selected, args.runtime, args.loader, logo)
            elif action == "launch":
                render(fb, games, selected, args.runtime, args.loader, logo)
                write_selection(args.selection, selected)
                return 0
            elif action == "back":
                return 2
    finally:
        for fd in list(devices.keys()):
            close_fd(fd)
        fb.close()


if __name__ == "__main__":
    raise SystemExit(main())
