#!/usr/bin/env python3
"""Fetch and unpack Shell A captures (`pcvrShellCapture` / `pcvrShellCaptureFrame`).

  lwcap.py fetch --frames 6 --out DIR
      records frames on the headset, downloads each blob to DIR/frame-N.lwcap
      and unpacks it. The address and token come from build-and-sign's session
      record (~/.local/state/debugtrace/sessions/pro.longwave.app@AVP.json,
      --session to name another); the token is never printed. The headset asks
      to allow the client once, and each frame download as a screen capture.
  lwcap.py unpack DIR/frame-0.lwcap [...]
      writes, next to each blob, a directory of PNGs and header.json:
        stream-left.png / stream-right.png  the stream frame shown (wire size,
                                            foveated packing as sent)
        depth.png                           the paired depth picture (luma)
        hud.png                             its HUD-mark chroma (Cb away from grey)
        viewN-colour.png                    what the warp handed the compositor,
                                            resampled to screen pixels by the rate map
        viewN-depth.png                     its depth, reverse Z, shown as 1/z scaled
        viewN-physical.png                  the same colour in physical pixels

Needs numpy and Pillow (Homebrew's python3.14 has both).
"""
import argparse
import json
import pathlib
import struct
import sys
import urllib.parse
import urllib.request

import numpy as np
from PIL import Image

MAGIC = b"LWCAP1\0\0"


def read(path):
    data = pathlib.Path(path).read_bytes()
    if data[:8] != MAGIC:
        raise SystemExit(f"{path}: not an LWCAP1 blob")
    (length,) = struct.unpack_from("<I", data, 8)
    header = json.loads(data[12:12 + length])
    base = 12 + length
    sections = {}
    for s in header["sections"]:
        raw = data[base + s["offset"]: base + s["offset"] + s["length"]]
        sections[s["name"]] = (s, raw)
    return header, sections


def image(section):
    s, raw = section
    w, h, row = s["width"], s["height"], s["bytesPerRow"]
    fmt = s["format"]
    if fmt.startswith("bgra8") or fmt == "rgba8":
        a = np.frombuffer(raw, np.uint8).reshape(h, row // 4, 4)[:, :w]
        return a[..., [2, 1, 0]] if fmt.startswith("bgra8") else a[..., :3]
    if fmt in ("depth32f", "r32f"):
        return np.frombuffer(raw, np.float32).reshape(h, row // 4)[:, :w]
    if fmt == "r8":
        return np.frombuffer(raw, np.uint8).reshape(h, row)[:, :w]
    if fmt == "rg8":
        return np.frombuffer(raw, np.uint8).reshape(h, row // 2, 2)[:, :w]
    if fmt == "f32":
        return np.frombuffer(raw, np.float32)
    raise SystemExit(f"unknown format {fmt}")


def to_screen(physical, xs, ys):
    """Nearest physical pixel for each screen pixel (the rate map is separable)."""
    xi = np.clip(np.floor(xs).astype(int), 0, physical.shape[1] - 1)
    yi = np.clip(np.floor(ys).astype(int), 0, physical.shape[0] - 1)
    return physical[yi[:, None], xi[None, :]]


def depth_png(z):
    # Reverse Z: larger is nearer. Show sqrt so the far field keeps some range.
    v = np.sqrt(np.clip(z / max(float(z.max()), 1e-9), 0, 1))
    return (v * 255).astype(np.uint8)


def unpack(path):
    header, sections = read(path)
    out = pathlib.Path(path).with_suffix("")
    out.mkdir(exist_ok=True)
    summary = {k: v for k, v in header.items() if k != "sections"}
    summary["sections"] = [s for s, _ in sections.values()]
    (out / "header.json").write_text(json.dumps(summary, indent=1))
    if "stream.colour" in sections:
        rgb = image(sections["stream.colour"])
        half = rgb.shape[1] // 2
        Image.fromarray(np.ascontiguousarray(rgb[:, :half])).save(out / "stream-left.png")
        Image.fromarray(np.ascontiguousarray(rgb[:, half:])).save(out / "stream-right.png")
    if "depth.luma" in sections:
        Image.fromarray(np.ascontiguousarray(image(sections["depth.luma"]))).save(out / "depth.png")
    if "depth.chroma" in sections:
        cb = image(sections["depth.chroma"])[..., 0].astype(int)
        Image.fromarray((np.abs(cb - 128) * 2).clip(0, 255).astype(np.uint8)).save(out / "hud.png")
    for view in range(4):
        name = f"view{view}"
        if f"{name}.colour" not in sections:
            continue
        colour = image(sections[f"{name}.colour"])
        Image.fromarray(np.ascontiguousarray(colour)).save(out / f"{name}-physical.png")
        xs = image(sections[f"{name}.rateX"]) if f"{name}.rateX" in sections else None
        ys = image(sections[f"{name}.rateY"]) if f"{name}.rateY" in sections else None
        if xs is not None and ys is not None:
            Image.fromarray(np.ascontiguousarray(to_screen(colour, xs, ys))).save(out / f"{name}-colour.png")
        if f"{name}.depth" in sections:
            z = image(sections[f"{name}.depth"])
            if xs is not None and ys is not None:
                z = to_screen(z, xs, ys)
            Image.fromarray(depth_png(z)).save(out / f"{name}-depth.png")
    print(f"{out}: frame {header.get('frameNumber')} new={header.get('isNew')} "
          f"depth={header.get('depth', {}).get('frameNumber')} sections={len(sections)}")
    return header


CLIENT = "lwcap (Longwave capture reader)"


def render_from_wire(u, c):
    """Render UV -> wire UV for one axis (`CentreEdgeAxisMapping.wireCoordinate`); c = (a, b, r, L)."""
    a, b, r, L = c
    packed = np.where(u < a, u / r, np.where(u <= b, a / r + u - a, a / r + b - a + (u - b) / r))
    return np.clip(packed / L, 0, 1)


def unwarped_eye(header, sections, eye, width, height):
    """The stream eye resampled to render space at width x height (nearest), float luma 0..1."""
    rgb = image(sections["stream.colour"]).astype(np.float32) / 255
    half = rgb.shape[1] // 2
    e = rgb[:, eye * half:(eye + 1) * half]
    u = (np.arange(width) + 0.5) / width
    v = (np.arange(height) + 0.5) / height
    fov = header.get("foveation")
    if fov:
        u = render_from_wire(u, fov["eyes"][eye]["x"])
        v = render_from_wire(v, fov["eyes"][eye]["y"])
    xi = np.clip((u * e.shape[1]).astype(int), 0, e.shape[1] - 1)
    yi = np.clip((v * e.shape[0]).astype(int), 0, e.shape[0] - 1)
    s = e[yi[:, None], xi[None, :]]
    return s @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def gradient(a):
    gx = np.zeros_like(a); gy = np.zeros_like(a)
    gx[:, 1:-1] = a[:, 2:] - a[:, :-2]
    gy[1:-1] = a[2:] - a[:-2]
    return np.hypot(gx, gy)


def align(path, reach=4):
    """How far the depth picture's edges sit from the colour's, per eye: the
    integer shift (depth texels) that best lines depth discontinuities up with
    colour edges, and how much better it scores than no shift. Depth that lags
    its colour by a game frame shows a shift along the camera's motion."""
    header, sections = read(path)
    if "depth.luma" not in sections or "stream.colour" not in sections:
        return None
    d = image(sections["depth.luma"]).astype(np.float32) / 255
    w = d.shape[1] // 2
    rows = []
    for eye in range(2):
        depth = d[:, eye * w:(eye + 1) * w]
        colour = unwarped_eye(header, sections, eye, w, depth.shape[0])
        dg = gradient(depth)
        dg = (dg > 0.02).astype(np.float32)  # depth discontinuities (inverse depth steps)
        cg = gradient(colour)
        m = reach + 2
        core = (slice(m, -m), slice(m, -m))
        best = None
        scores = {}
        for dy in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                shifted = np.roll(np.roll(cg, dy, 0), dx, 1)
                score = float((dg[core] * shifted[core]).sum() / max(dg[core].sum(), 1))
                scores[(dx, dy)] = score
                if best is None or score > best[0]:
                    best = (score, dx, dy)
        rows.append({"eye": eye, "bestShift": [best[1], best[2]], "bestScore": round(best[0], 4),
                     "zeroScore": round(scores[(0, 0)], 4), "edgeTexels": int(dg[core].sum())})
    return {"frame": header.get("frameNumber"), "isNew": header.get("isNew"),
            "depthFrame": header.get("depth", {}).get("frameNumber"), "eyes": rows}


def call(url, token, endpoint, args, binary=False):
    headers = {"Authorization": f"Bearer {token}", "X-DebugTrace-Client": CLIENT}
    if binary:  # a query: GET with the arguments in the query string
        query = urllib.parse.urlencode(args)
        request = urllib.request.Request(f"{url}/{endpoint}?{query}", method="GET", headers=headers)
    else:
        headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"{url}/{endpoint}", data=json.dumps(args).encode(), method="POST",
                                         headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read()
    return body if binary else json.loads(body)


def fetch(args):
    record = json.loads(pathlib.Path(args.session).expanduser().read_text())
    args.url = args.url or record["url"]
    args.token = record.get("token", "")
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    result = call(args.url, args.token, args.prefix + "pcvrShellCapture", {"frames": args.frames, "stride": args.stride})
    result = result.get("data", result)
    (out / "capture.json").write_text(json.dumps(result, indent=1))
    print(json.dumps({k: v for k, v in result.items() if k != "frames"}))
    for row in result.get("frames", []):
        if not row.get("complete"):
            continue
        blob = call(args.url, args.token, args.prefix + "pcvrShellCaptureFrame", {"index": row["index"]}, binary=True)
        path = out / f"frame-{row['index']}.lwcap"
        path.write_bytes(blob)
        unpack(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--session", default="~/.local/state/debugtrace/sessions/pro.longwave.app@AVP.json")
    f.add_argument("--url", default="", help="the app's debug server (default: the session record's)")
    f.add_argument("--prefix", default="", help="path before the endpoint name, as the server's help gives it")
    f.add_argument("--frames", type=int, default=4)
    f.add_argument("--stride", type=int, default=1)
    f.add_argument("--out", required=True)
    u = sub.add_parser("unpack")
    u.add_argument("paths", nargs="+")
    a = sub.add_parser("align", help="depth-to-colour edge alignment per blob")
    a.add_argument("paths", nargs="+")
    args = parser.parse_args()
    if args.command == "fetch":
        fetch(args)
    elif args.command == "align":
        for path in args.paths:
            print(json.dumps(align(path)))
    else:
        for path in args.paths:
            unpack(path)


if __name__ == "__main__":
    sys.exit(main())
