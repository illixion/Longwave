// SPIKE ONLY: a full-screen test pattern that changes every display refresh,
// so capture has a new frame to deliver at the display's full rate (WGC and
// DXGI duplication only produce frames when something changes). Run it as its
// own process so its drawing doesn't count against the host's CPU.
//
// Each refresh it draws a block of random noise at a random position (hard
// for the encoder: no motion prediction helps), a bar sweeping across the
// screen, and a frame counter. Plain Win32 + GDI from Swift via WinSDK.
import StreamHostWindows
import WinSDK

private func wide(_ string: String) -> [WCHAR] { Array(string.utf16) + [0] }

func runAnimator(monitor: Monitor, seconds: Double) {
    let instance = GetModuleHandleW(nil)
    let className = wide("LongwaveSpikeAnimator")
    var windowClass = WNDCLASSEXW()
    windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    windowClass.lpfnWndProc = { hwnd, message, wParam, lParam in
        DefWindowProcW(hwnd, message, wParam, lParam)
    }
    windowClass.hInstance = instance
    windowClass.hbrBackground = HBRUSH(OpaquePointer(GetStockObject(BLACK_BRUSH)))
    className.withUnsafeBufferPointer { windowClass.lpszClassName = $0.baseAddress }
    guard RegisterClassExW(&windowClass) != 0 else { fail("RegisterClassExW failed (\(GetLastError()))") }

    let width = Int32(monitor.width)
    let height = Int32(monitor.height)
    let title = wide("Longwave spike test pattern")
    guard let window = CreateWindowExW(DWORD(WS_EX_TOPMOST | WS_EX_TOOLWINDOW), className, title,
                                       WS_POPUP | DWORD(WS_VISIBLE),
                                       Int32(monitor.x), Int32(monitor.y), width, height, nil, nil, instance, nil)
    else { fail("CreateWindowExW failed (\(GetLastError()))") }

    // Noise source: a quarter-screen 32-bit DIB filled once with random bytes.
    let noiseWidth = width / 2
    let noiseHeight = height / 2
    var bitmapInfo = BITMAPINFO()
    bitmapInfo.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
    bitmapInfo.bmiHeader.biWidth = noiseWidth
    bitmapInfo.bmiHeader.biHeight = -noiseHeight
    bitmapInfo.bmiHeader.biPlanes = 1
    bitmapInfo.bmiHeader.biBitCount = 32
    bitmapInfo.bmiHeader.biCompression = DWORD(BI_RGB)
    var bits: UnsafeMutableRawPointer?
    let screenDC = GetDC(window)
    guard let noise = CreateDIBSection(screenDC, &bitmapInfo, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
        fail("CreateDIBSection failed")
    }
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let words = bits.bindMemory(to: UInt64.self, capacity: Int(noiseWidth * noiseHeight) / 2)
    for i in 0..<(Int(noiseWidth * noiseHeight) / 2) {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        words[i] = state
    }
    let noiseDC = CreateCompatibleDC(screenDC)
    SelectObject(noiseDC, noise)
    ReleaseDC(window, screenDC)

    let frequency: Int64 = { var f = LARGE_INTEGER(); QueryPerformanceFrequency(&f); return f.QuadPart }()
    func now() -> Int64 { var t = LARGE_INTEGER(); QueryPerformanceCounter(&t); return t.QuadPart }
    let end = now() + Int64(seconds * Double(frequency))
    var frame = 0
    var message = MSG()
    let barBrush = CreateSolidBrush(COLORREF(0x00_30_C0_FF))
    let blackBrush = HBRUSH(OpaquePointer(GetStockObject(BLACK_BRUSH)))
    var previousBar = RECT()
    while now() < end {
        while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        guard let dc = GetDC(window) else { break }
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        let x = Int32(truncatingIfNeeded: state % UInt64(width - noiseWidth))
        let y = Int32(truncatingIfNeeded: (state >> 32) % UInt64(height - noiseHeight))
        BitBlt(dc, x, y, noiseWidth, noiseHeight, noiseDC, 0, 0, DWORD(SRCCOPY))
        // Sweeping bar: erase the old one, draw the new one.
        FillRect(dc, &previousBar, blackBrush)
        let barX = Int32(frame * 16 % Int(width))
        var bar = RECT(left: barX, top: 0, right: barX + 48, bottom: height)
        FillRect(dc, &bar, barBrush)
        previousBar = bar
        let label = wide("frame \(frame)")
        TextOutW(dc, 40, 40, label, Int32(label.count - 1))
        ReleaseDC(window, dc)
        frame += 1
        DwmFlush() // wait for the next composition: one update per refresh
    }
    print("animator drew \(frame) frames in \(seconds) s")
    DeleteObject(barBrush)
    DeleteDC(noiseDC)
    DeleteObject(noise)
    DestroyWindow(window)
}
