"""Foveated twins of the engine's screen-space compute shaders (engine stereo, both eyes side by side).

Outside an ellipse around each eye's centre the pass does no work and stores what the engine itself stores
where there is nothing to do. The ellipse is in each eye's own 0..1 image coordinates, so it holds at any
render size. Built on the port's hidden-area recipe tools (tools/hidden_area_tests/ham_shaders.py).

  python fov_shaders.py --shaders ROOT --out OUT_DIR [--rx 0.40 --ry 0.38 --nose 0.03 --cy 0.45]

ROOT holds shaders\<fnv>.dxil (the engine's shaders, from the census) and twins\<fnv>.dxil (the port's own twins
of them, from its shaders\asym_ao folder), each named by the engine shader's FNV-1a.
"""
import argparse
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, r'C:\lwvr\cpvr\repo\tools\hidden_area_tests')
import ham_shaders as ham  # noqa: E402
import dxil_container as dc  # noqa: E402

ham.DXIL_TOOL = Path(r'C:\lwvr\cpvr\dxil_tool.exe')

STORE = (r'(?m)^  call void @dx\.op\.textureStore\.f32\(i32 67, %dx\.types\.Handle (%\d+), i32 (%\d+), '
         r'i32 (%\d+), i32 undef, float %[\w.]+, float %[\w.]+, float %[\w.]+, float %[\w.]+, i8 15\)')
UNOCCLUDED = ('  call void @dx.op.textureStore.f32(i32 67, %%dx.types.Handle %s, i32 %s, i32 %s, i32 undef, '
              'float 5.000000e-01, float 5.000000e-01, float 1.000000e+00, float 1.000000e+00, i8 15)')


def inside(u, v, a):
    """IR lines defining %fov.vis (i1): the pixel at frame uv (u across both eyes) is inside its eye's ellipse."""
    lit = ham.lit
    return [
        f'  %fov.u2 = fmul fast float {u}, 2.000000e+00',
        '  %fov.right = fcmp fast oge float %fov.u2, 1.000000e+00',
        '  %fov.u2r = fadd fast float %fov.u2, -1.000000e+00',
        '  %fov.eu = select i1 %fov.right, float %fov.u2r, float %fov.u2',
        f'  %fov.cx = select i1 %fov.right, float {lit(0.5 - a.nose)}, float {lit(0.5 + a.nose)}',
        '  %fov.dx0 = fsub fast float %fov.eu, %fov.cx',
        f'  %fov.dx = fmul fast float %fov.dx0, {lit(1.0 / a.rx)}',
        f'  %fov.dy0 = fsub fast float {v}, {lit(a.cy)}',
        f'  %fov.dy = fmul fast float %fov.dy0, {lit(1.0 / a.ry)}',
        '  %fov.xx = fmul fast float %fov.dx, %fov.dx',
        '  %fov.yy = fmul fast float %fov.dy, %fov.dy',
        '  %fov.d = fadd fast float %fov.xx, %fov.yy',
        '  %fov.vis = fcmp fast ole float %fov.d, 1.000000e+00',
    ]


def split_after(ir, anchor, test, skip):
    """Split the entry block after `anchor`: pixels for which %fov.vis holds run the original code, the rest `skip`."""
    start, end = ham.function_body(ir)
    body = ir[start:end]
    body = body.replace('\n  ret void', '\n  br label %fov.exit')
    body = re.sub(r'(?m)^(  %\S+ = phi .*)$', lambda m: re.sub(r'%0 \]', '%fov.body ]', m.group(1)), body)
    body = ham.replace_once(body, anchor, anchor + '\n'.join(
        list(test) + ['  br i1 %fov.vis, label %fov.body, label %fov.skip', '', 'fov.skip:'] + list(skip) +
        ['  br label %fov.exit', '', 'fov.body:']) + '\n')
    return ir[:start] + body + '\n\nfov.exit:\n  ret void' + ir[end:]


def one_store(ir):
    store = re.findall(STORE, ir)
    if len(store) != 1:
        raise ValueError('expected one store, found %d' % len(store))
    return store[0]


def cone_trace(ir, a):
    """DrawConeAO's 8x8 pass with uv = (thread + origin) * texel as its first two float products."""
    m = re.search(r'(?m)^  (%\d+) = fmul fast float %\d+, %\d+\n  (%\d+) = fmul fast float %\d+, %\d+\n', ir)
    if not m:
        raise ValueError('uv pair not found')
    return split_after(ir, m.group(0), inside(m.group(1), m.group(2), a), [UNOCCLUDED % one_store(ir)])


def cone_main(ir, a):
    """DrawConeAO's main trace (16x16 groups, one pixel per thread; the port's two-eye twin of it). The frame's
    size is row 1.zw of its block. Outside the ellipse: no occlusion, a straight bent normal."""
    m = re.search(r'(?m)^  (%\d+) = call i32 @dx\.op\.threadId\.i32\(i32 93, i32 0\)[^\n]*\n'
                  r'  (%\d+) = call i32 @dx\.op\.threadId\.i32\(i32 93, i32 1\)[^\n]*\n', ir)
    cb = re.search(r'(?m)^  (%\d+) = call %dx\.types\.Handle @dx\.op\.createHandle\(i32 57, i8 2, i32 0, i32 3, i1 false\)', ir)
    if not m or not cb:
        raise ValueError('thread id pair or block handle not found')
    test = [
        f'  %fov.l1 = call %dx.types.CBufRet.f32 @dx.op.cbufferLoadLegacy.f32(i32 59, %dx.types.Handle {cb.group(1)}, i32 1)',
        '  %fov.w = extractvalue %dx.types.CBufRet.f32 %fov.l1, 2',
        '  %fov.h = extractvalue %dx.types.CBufRet.f32 %fov.l1, 3',
        f'  %fov.xi = uitofp i32 {m.group(1)} to float',
        f'  %fov.yi = uitofp i32 {m.group(2)} to float',
        '  %fov.xc = fadd fast float %fov.xi, 5.000000e-01',
        '  %fov.yc = fadd fast float %fov.yi, 5.000000e-01',
        '  %fov.u = fdiv fast float %fov.xc, %fov.w',
        '  %fov.v = fdiv fast float %fov.yc, %fov.h',
    ] + inside('%fov.u', '%fov.v', a)
    return split_after(ir, m.group(0), test, [UNOCCLUDED % one_store(ir)])


# engine shader's FNV-1a -> (name, recipe, source folder: the engine's shader, or the port's twin of it to build on)
RECIPES = {
    0x65e542c0719b464d: ('DrawConeAO 8x8 pass', cone_trace, 'shaders'),
    0x33f28d9a0e7a8352: ('DrawConeAO main trace (on the port twin)', cone_main, 'twins'),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shaders', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--rx', type=float, default=0.40)
    ap.add_argument('--ry', type=float, default=0.38)
    ap.add_argument('--nose', type=float, default=0.03)
    ap.add_argument('--cy', type=float, default=0.45)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    for key, (name, recipe, folder) in RECIPES.items():
        original = (a.shaders / folder / ('%016x.dxil' % key)).read_bytes()
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            try:
                ir = recipe(ham.disassemble(original, work), a)
                (a.out / ('%016x.ll' % key)).write_text(ir)
                container = ham.assemble(ir, work)
            except Exception as error:
                print('FAIL %016x %s: %s' % (key, name, str(error)[-1500:]))
                continue
        if dc.dxil_hash(container) != container[4:20]:
            print('FAIL %016x %s: validator hash mismatch' % (key, name))
            continue
        (a.out / ('%016x.dxil' % key)).write_bytes(container)
        print('OK   %016x %s (%d bytes)' % (key, name, len(container)))


main()
