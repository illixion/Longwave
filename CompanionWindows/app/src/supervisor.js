'use strict';
/**
 * Process supervision for the PCVR host, owned by this app rather than by Windows.
 *
 * It replaces the `Longwave-Broker` / `Longwave-Sidecar` scheduled tasks, each of which
 * ran a `.bat` that redirected to a log file. That arrangement had three faults that cost
 * a whole afternoon on 2026-07-28:
 *
 *   1. Every service appeared as a **console window on the desktop**, indistinguishable
 *      from junk. Closing them — the obvious thing to do with a stray CMD window — removed
 *      the broker, and with it everything the headset depends on: the broker is the only
 *      thing that renders and the only thing that relays the game-library RPC, so the
 *      symptom was a black portal and a library that never answered. Nothing on screen
 *      connected the two.
 *   2. The **start order lived in a person's head**. Backend, then the foveated host, then
 *      the CloudXR runtime service, then the broker, then the sidecar. Out of order the broker
 *      fails `xrCreateInstance` with -51 and blames a missing runtime.
 *   3. A scheduled task **outlives the app**, so a service could keep running against a
 *      closed UI, and `Stop-ScheduledTask` was the only way to reach it.
 *
 * Children here are spawned with `windowsHide` and no `cmd` in the chain, so there are no
 * console windows at all; their output is piped to `logs\<name>.log` by us; and they are
 * killed when the app quits, because a helper that outlives its owner is a bug.
 *
 * Deliberately NOT managed here: NvStreamManager and CloudXrService. Those are the
 * backend's children, started through its `FoveatedStart` / `FoveatedStartRuntime` RPCs,
 * and taking them over would mean reimplementing the DPAPI-sensitive startup the backend
 * already gets right. `startStack()` calls those RPCs in order instead.
 */
const path = require('path');
const fs = require('fs');
const { spawn, execFile, execFileSync } = require('child_process');
const { EventEmitter } = require('events');
const net = require('net');

const BROKER_CONTROL_PIPE = '\\\\.\\pipe\\Longwave.SessionBroker.Control';

function requestBrokerControl(command, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let response = '';
    const socket = net.createConnection(BROKER_CONTROL_PIPE);
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error);
      else resolve(value);
    };
    const timer = setTimeout(
      () => finish(new Error(`session broker control timed out after ${timeoutMs} ms`)),
      timeoutMs);
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(`${command}\n`));
    socket.on('data', (chunk) => {
      response += chunk;
      const newline = response.indexOf('\n');
      if (newline < 0) return;
      try {
        finish(null, JSON.parse(response.slice(0, newline)));
      } catch (e) {
        finish(new Error(`invalid session broker response: ${e.message}`));
      }
    });
    socket.on('error', (e) => finish(e));
    socket.on('end', () => {
      if (!settled) finish(new Error('session broker closed the control pipe without a response'));
    });
  });
}

/**
 * Image names of processes we would otherwise try to start a second copy of. Checked with
 * `tasklist` rather than a library: no dependency, and the answer is only needed on a
 * button press.
 */
function isProcessRunning(imageName) {
  return new Promise((resolve) => {
    execFile('tasklist', ['/FI', `IMAGENAME eq ${imageName}`, '/NH', '/FO', 'CSV'], (err, stdout) => {
      if (err) return resolve(false);
      /* Judged by whether the filter matched anything, NOT by finding the name in the
         output: tasklist truncates the image-name column, so "LongwaveSessionBroker.exe"
         never appears in full and a substring test silently always said "not running".
         When nothing matches, tasklist prints an INFO: line instead of rows. */
      const text = stdout.trim();
      resolve(text.length > 0 && !text.startsWith('INFO:'));
    });
  });
}

/**
 * Waits for the CloudXR runtime's Monado IPC pipe to appear.
 *
 * The pipe's name embeds the per-user temp path (`\\.\pipe\C:\Users\<u>\AppData\Local\Temp\
 * /ipc_cloudxr`), so it is matched by suffix rather than reconstructed — the exact spelling
 * is CloudXR's business and has a stray slash in it. Enumerating `\\.\pipe\` is the only
 * way to ask "does this exist" without connecting to it and disturbing whatever is there.
 */
function waitForCloudXrPipe(timeoutMs) {
  const started = Date.now();
  return new Promise((resolve) => {
    const poll = () => {
      let found = false;
      try {
        found = fs.readdirSync('\\\\.\\pipe\\').some((name) => /ipc_cloudxr$/i.test(name));
      } catch { /* the pipe namespace is unreadable; treat as not ready and retry */ }
      const waitedMs = Date.now() - started;
      if (found) return resolve({ ok: true, waitedMs });
      if (waitedMs >= timeoutMs) return resolve({ ok: false, waitedMs });
      setTimeout(poll, 250);
    };
    poll();
  });
}

/** Where service logs go: the install's `logs\`, beside the backend's own. */
function resolveLogDirectory(appRoot) {
  const candidates = [
    path.join(appRoot, '..', 'logs'),
    path.join(appRoot, 'logs'),
  ];
  for (const dir of candidates) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      return dir;
    } catch { /* try the next */ }
  }
  return appRoot;
}

/**
 * The CloudXR OpenXR runtime manifest, which the broker must be pointed at explicitly so
 * that the machine default can belong to games (VDXR), exactly as it does under Virtual
 * Desktop. Found by looking for the newest `releases\<version>\` rather than naming a
 * version: the SDK is hand-staged, and a future SDK lands in a differently-named directory.
 */
function resolveCloudXrRuntimeJson(backendExe) {
  if (!backendExe) return null;
  const releases = path.join(path.dirname(backendExe), 'Server', 'releases');
  let versions;
  try { versions = fs.readdirSync(releases); } catch { return null; }
  const found = versions
    .map((v) => path.join(releases, v, 'openxr_cloudxr.json'))
    .filter((p) => fs.existsSync(p))
    .sort();
  return found.length ? found[found.length - 1] : null;
}

const KHRONOS_KEY = 'HKLM\\SOFTWARE\\Khronos\\OpenXR\\1';

/**
 * The runtime every app should get while we are hosting: VDXR. `LONGWAVE_VDXR_JSON`
 * overrides it for a non-standard install.
 */
function resolveVdxrJson() {
  const candidates = [
    process.env.LONGWAVE_VDXR_JSON,
    'C:\\dev\\vdxr\\bin\\x64\\Release\\virtualdesktop-openxr.json',
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p)) || null;
}

/** First existing path, or null. */
function firstExisting(candidates) {
  return candidates.find((p) => fs.existsSync(p)) || null;
}

class Supervisor extends EventEmitter {
  /**
   * @param {object} options
   * @param {string} options.appRoot         the app directory (…\app)
   * @param {string|null} options.backendExe resolved backend executable, for runtime paths
   * @param {string|null} options.bridgeRoot directory holding the broker + sidecar binaries
   */
  constructor({ appRoot, backendExe, bridgeRoot }) {
    super();
    this.logDirectory = resolveLogDirectory(appRoot);
    this.runtimeJson = resolveCloudXrRuntimeJson(backendExe);
    this.bridgeRoot = bridgeRoot;
    /* Per-start broker settings from the panel, read when the broker is spawned. Defaulted
       here so a broker restarted outside startStack() — the crash path, which has
       restart:true — still finds an object rather than throwing on a missing field. */
    this.brokerOptions = { desktopQuad: false };
    /** @type {Map<string, {proc: import('child_process').ChildProcess, stopping: boolean, restarts: number, startedAt: number}>} */
    this.running = new Map();
    /** @type {Map<string, NodeJS.Timeout>} */
    this.restartTimers = new Map();
    /** Last exit per service name, so a one-shot's success survives its own exit, and so a
     *  restart count is still readable after the thing finally gave up — which is exactly
     *  when someone wants to know how many times it tried. */
    /** @type {Map<string, {code: number|null, at: number, restarts: number}>} */
    this.exits = new Map();
    this.vdxrJson = resolveVdxrJson();
    /* Where the runtime we displaced is remembered. On disk rather than in memory so that a
       crash does not lose it: the next run restores from here instead of overwriting it. */
    this.claimRecordPath = path.join(this.logDirectory, 'activeruntime-before-claim.txt');
    this.definitions = this.#defineServices();
  }

  /**
   * Re-resolves the CloudXR runtime manifest and the broker/sidecar directory. Both are only
   * ever computed once at construction, which is exactly wrong for an on-demand PCVR install:
   * the Supervisor is built at app startup, before the user has downloaded anything, so a
   * successful download has to push the newly-discoverable paths in rather than wait for a
   * restart.
   */
  refreshPaths(backendExe, bridgeRoot) {
    this.runtimeJson = resolveCloudXrRuntimeJson(backendExe);
    this.bridgeRoot = bridgeRoot;
    this.definitions = this.#defineServices();
  }

  // ---- OpenXR runtime claim ------------------------------------------------
  //
  // Held only while we are hosting, and handed back afterwards, because this machine
  // setting is global: leaving it pointed at VDXR would quietly hijack SteamVR with another
  // headset on the same PC. The registry has to be the mechanism (a per-user HKCU override
  // is ignored by the loader — measured 2026-07-28: with HKLM naming CloudXR and HKCU naming
  // VDXR, hello_xr loaded CloudXR), and provisioning grants this user SetValue on that one
  // key so claiming needs no elevation and therefore no consent prompt.

  #readActiveRuntime() {
    try {
      const out = execFileSync('reg', ['query', KHRONOS_KEY, '/v', 'ActiveRuntime'],
                               { encoding: 'utf8' });
      const match = out.match(/ActiveRuntime\s+REG_SZ\s+(.+)/);
      return match ? match[1].trim() : null;
    } catch {
      return null;   // key or value absent
    }
  }

  #writeActiveRuntime(value) {
    try {
      execFileSync('reg', ['add', KHRONOS_KEY, '/v', 'ActiveRuntime', '/t', 'REG_SZ',
                           '/d', value, '/f'], { stdio: 'ignore' });
      return true;
    } catch (e) {
      this.emit('log', `Could not set the OpenXR runtime (${e.message}). `
        + 'Re-run provisioning: it grants this user write access to that key.');
      return false;
    }
  }

  /** Point every app at VDXR, remembering what was there. */
  claimRuntime() {
    if (!this.vdxrJson) {
      this.emit('log', 'VDXR not found; leaving the OpenXR runtime alone');
      return { ok: false, detail: 'VDXR manifest not found' };
    }
    const current = this.#readActiveRuntime();
    if (current && current.toLowerCase() === this.vdxrJson.toLowerCase()) {
      return { ok: true, already: true };
    }
    if (!this.#writeActiveRuntime(this.vdxrJson)) return { ok: false };
    // Recorded only after the write actually succeeded, and only on the transition into our
    // claim: claiming twice must not overwrite the record with our own value and lose the
    // user's runtime for good.
    if (!fs.existsSync(this.claimRecordPath)) {
      try { fs.writeFileSync(this.claimRecordPath, current || ''); } catch { /* best effort */ }
    }
    this.emit('log', `OpenXR runtime claimed for VDXR (was ${current || 'unset'})`);
    return { ok: true };
  }

  /** Hand the machine's runtime back to whatever had it. */
  releaseRuntime() {
    let previous = null;
    try {
      if (fs.existsSync(this.claimRecordPath)) {
        previous = fs.readFileSync(this.claimRecordPath, 'utf8').trim();
      }
    } catch { /* fall through */ }
    if (previous === null) return { ok: true, already: true };

    const current = this.#readActiveRuntime();
    // Someone else has claimed it since; theirs wins, and our record is stale.
    const ours = this.vdxrJson && current && current.toLowerCase() === this.vdxrJson.toLowerCase();
    if (ours) {
      if (previous) this.#writeActiveRuntime(previous);
      else {
        try { execFileSync('reg', ['delete', KHRONOS_KEY, '/v', 'ActiveRuntime', '/f'], { stdio: 'ignore' }); }
        catch { /* nothing to delete */ }
      }
      this.emit('log', `OpenXR runtime released back to ${previous || 'unset'}`);
    }
    try { fs.unlinkSync(this.claimRecordPath); } catch { /* already gone */ }
    return { ok: true };
  }

  #defineServices() {
    const bridge = this.bridgeRoot;
    const bin = (name) => (bridge ? [path.join(bridge, name)] : []);
    return {
      broker: {
        title: 'Session broker',
        image: 'LongwaveSessionBroker.exe',
        exe: () => firstExisting(bin('LongwaveSessionBroker.exe')),
        args: [],
        env: () => ({
          LONGWAVE_CB_LAYER_LOG: path.join(this.logDirectory, 'cb_broker.log'),
          // Pushes the composited layer far enough away that it reads as a world rather
          // than a screen; matches the value the old start-broker.bat set.
          LONGWAVE_BROKER_DEPTH_PLANE_M:
            process.env.LONGWAVE_BROKER_DEPTH_PLANE_M ?? '50',
          LONGWAVE_BROKER_TIMEWARP:
            process.env.LONGWAVE_BROKER_TIMEWARP ?? '1',
          // Desktop-in-a-quad. Driven by the panel's own switch, because an environment
          // variable turned out to be a promise this app cannot keep: setting one at User
          // scope does not reach an Electron already launched from a shell that predates
          // it, so the toggle looked on while the broker never saw it and the desktop
          // simply failed to appear with nothing in any log to say why. The env var still
          // works for a headless run; the switch wins when it is on.
          ...(this.brokerOptions.desktopQuad || process.env.LONGWAVE_BROKER_TEST_QUAD
            ? { LONGWAVE_BROKER_TEST_QUAD: '1' }
            : {}),
          ...(process.env.LONGWAVE_BROKER_TEST_QUAD_SRGB
            ? { LONGWAVE_BROKER_TEST_QUAD_SRGB: process.env.LONGWAVE_BROKER_TEST_QUAD_SRGB }
            : {}),
          ...(process.env.LONGWAVE_BROKER_TEST_QUAD_DISTANCE_M
            ? { LONGWAVE_BROKER_TEST_QUAD_DISTANCE_M:
                  process.env.LONGWAVE_BROKER_TEST_QUAD_DISTANCE_M }
            : {}),
          ...(process.env.LONGWAVE_BROKER_TEST_QUAD_HEIGHT_M
            ? { LONGWAVE_BROKER_TEST_QUAD_HEIGHT_M:
                  process.env.LONGWAVE_BROKER_TEST_QUAD_HEIGHT_M }
            : {}),
          ...(this.runtimeJson ? { XR_RUNTIME_JSON: this.runtimeJson } : {}),
        }),
        // The broker is the session. If it dies mid-stream the headset is left on a black
        // portal, so bring it straight back.
        restart: true,
      },
      sidecar: {
        title: 'Sidecar',
        image: 'sidecar_inject.exe',
        exe: () => firstExisting(bin('sidecar_inject.exe')),
        /* --watch, and this is the difference between working and appearing to.
           `CloudXrService` is not our child: the backend starts NvStreamManager, which spawns
           the service over RPC, and it is respawned per streaming session — more than once per
           boot, without us being told. A single injection at stack start therefore patches the
           service that happens to exist at that moment and nothing after it, so every session
           past the first ran unpatched while the UI reported the sidecar healthy. Resident mode
           polls once a second and injects into any CloudXrService lacking sidecar.dll;
           InjectOnce is idempotent, so it needs no state of its own. */
        args: ['--watch'],
        env: () => ({}),
        /* A watcher that dies takes the fix with it for every later session, and it is cheap to
           restart (it injects into an already-running service, so nothing else has to bounce). */
        restart: true,
        /* No longer a one-shot: in --watch mode a clean exit is the failure — it means nothing
           is left looking for the next service. Health is "the process is alive" again. */
        oneShot: false,
      },
    };
  }

  /** Names of every service this supervisor knows about. */
  get names() {
    return Object.keys(this.definitions);
  }

  /**
   * Per-service state, including `healthy` — the single question the UI should ask.
   * For a long-running service that means the process is alive; for a one-shot it means
   * it ran and exited zero, because that is what "the hook is installed" looks like.
   */
  status() {
    const out = {};
    for (const [name, definition] of Object.entries(this.definitions)) {
      const live = this.running.get(name);
      const exit = this.exits.get(name);
      const running = Boolean(live && live.proc.exitCode === null);
      const completed = Boolean(definition.oneShot && exit && exit.code === 0);
      out[name] = {
        title: definition.title,
        oneShot: Boolean(definition.oneShot),
        running,
        completed,
        healthy: running || completed,
        lastExitCode: exit ? exit.code : null,
        pid: live ? live.proc.pid : null,
        exe: definition.exe(),
        restarts: live ? live.restarts : (exit ? exit.restarts : 0),
      };
    }
    return out;
  }

  /**
   * Refuses to start a service that is already running outside this app — a leftover
   * scheduled task, or a second copy of the UI. Starting a second broker does not replace
   * the first: it fails on CloudXR's handshake, exits, gets restarted, and the restart
   * counter climbs while the actual session carries on working, which is exactly as
   * confusing as it sounds. Reported so the message names the cause.
   */
  async startChecked(name) {
    const definition = this.definitions[name];
    if (!definition) throw new Error(`unknown service: ${name}`);
    const live = this.running.get(name);
    if (!live && definition.image && await isProcessRunning(definition.image)) {
      const detail = `${definition.title} is already running, started outside this app `
        + '(a leftover scheduled task, or another copy of the companion). '
        + 'Stop that one first — starting a second would just fail and retry.';
      this.emit('log', detail);
      return { ok: false, detail, foreign: true };
    }
    return this.start(name);
  }

  start(name, { restarts = 0 } = {}) {
    const definition = this.definitions[name];
    if (!definition) throw new Error(`unknown service: ${name}`);
    this.#cancelRestart(name);
    const existing = this.running.get(name);
    if (existing && existing.proc.exitCode === null) return { ok: true, already: true };

    const exe = definition.exe();
    if (!exe) {
      const detail = `${definition.title}: executable not found${this.bridgeRoot ? ` in ${this.bridgeRoot}` : ' (no bridge directory configured)'}`;
      this.emit('log', detail);
      return { ok: false, detail };
    }

    const logPath = path.join(this.logDirectory, `${name}.log`);
    // Truncated per start, like the .bat's `>` did: the question a service log answers is
    // "what happened this run", and the previous run's tail masquerading as this one's is
    // exactly how an afternoon goes missing.
    let logStream = null;
    try {
      logStream = fs.createWriteStream(logPath, { flags: 'w' });
      /* Failure arrives on the stream, not from the call, so a try/catch alone never sees
         it — and an unhandled 'error' event takes down the whole main process. Which is
         reachable in practice: anything else holding this path open (a leftover
         scheduled task redirecting into the same file) makes the open fail with EBUSY. */
      logStream.on('error', (e) => {
        this.emit('log', `${definition.title}: cannot write ${logPath} (${e.code || e.message}); continuing without a log`);
        logStream = null;
      });
      logStream.write(`=== ${name} started ${new Date().toISOString()} ===\r\n`);
    } catch (e) {
      this.emit('log', `${definition.title}: cannot open ${logPath}: ${e.message}`);
      logStream = null;
    }

    const proc = spawn(exe, definition.args, {
      cwd: path.dirname(exe),
      windowsHide: true,
      env: { ...process.env, ...definition.env() },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    // Written by hand rather than with pipe(), because the destination can go away
    // mid-run and a chatty service whose output is never read blocks on a full pipe.
    for (const stream of [proc.stdout, proc.stderr]) {
      stream.on('data', (chunk) => { if (logStream) logStream.write(chunk); });
    }

    const entry = { proc, stopping: false, restarts, startedAt: Date.now() };
    this.running.set(name, entry);
    this.exits.delete(name);
    this.emit('log', `${definition.title} started (pid ${proc.pid})`);
    this.emit('changed', this.status());

    proc.on('error', (e) => {
      this.emit('log', `${definition.title} failed to start: ${e.message}`);
    });
    proc.on('exit', (code, signal) => {
      if (logStream) {
        try {
          logStream.end(`=== exited ${new Date().toISOString()} code ${code} signal ${signal} ===\r\n`);
        } catch { /* the stream already failed; its error handler said so */ }
      }
      this.running.delete(name);
      this.exits.set(name, { code, at: Date.now(), restarts: entry.restarts });
      this.emit('log', definition.oneShot && code === 0
        ? `${definition.title} finished (hook installed)`
        : `${definition.title} exited (code ${code})`);
      this.emit('changed', this.status());

      if (entry.stopping || this.shuttingDown || !definition.restart) return;
      // A service that dies immediately and repeatedly is misconfigured, not unlucky —
      // restarting it forever would bury the real error under its own log churn.
      const lived = Date.now() - entry.startedAt;
      if (lived < 5000 && entry.restarts >= 3) {
        this.emit('log', `${definition.title} keeps exiting immediately; not restarting again`);
        return;
      }
      const nextRestarts = lived < 5000 ? entry.restarts + 1 : 0;
      this.exits.set(name, { code, at: Date.now(), restarts: nextRestarts });
      const timer = setTimeout(() => {
        this.restartTimers.delete(name);
        if (!this.shuttingDown) this.start(name, { restarts: nextRestarts });
      }, 1500);
      this.restartTimers.set(name, timer);
    });

    return { ok: true, pid: proc.pid };
  }

  stop(name) {
    this.#cancelRestart(name);
    const live = this.running.get(name);
    if (!live) return { ok: true, already: true };
    live.stopping = true;
    try { live.proc.kill(); } catch { /* already gone */ }
    return { ok: true };
  }

  #cancelRestart(name) {
    const timer = this.restartTimers.get(name);
    if (!timer) return;
    clearTimeout(timer);
    this.restartTimers.delete(name);
  }

  async stopAndWait(name, timeoutMs = 3000) {
    this.#cancelRestart(name);
    const live = this.running.get(name);
    if (!live) return { ok: true, already: true };
    const { proc } = live;
    const pid = proc.pid;
    this.stop(name);

    const exited = await new Promise((resolve) => {
      if (proc.exitCode !== null) return resolve(true);
      const onExit = () => {
        clearTimeout(timer);
        resolve(true);
      };
      const timer = setTimeout(() => {
        proc.removeListener('exit', onExit);
        resolve(false);
      }, timeoutMs);
      proc.once('exit', onExit);
    });
    if (exited || !pid) return { ok: true };

    // A broker that ignores the polite termination must not survive beneath a stopped UI.
    await new Promise((resolve) => {
      execFile('taskkill', ['/PID', String(pid), '/T', '/F'], () => resolve());
    });
    if (proc.exitCode === null) {
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 1000);
        proc.once('exit', () => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
    return { ok: true, forced: true };
  }

  /**
   * Bring the PCVR stack up in the one order that works, so it stops being something to
   * remember. `rpc` is the backend pipe client's `rpc(method, params)`.
   *
   * The CloudXR runtime has to be up before the broker starts or `xrCreateInstance`
   * returns -51 — and every symptom of that points at a broken runtime install rather
   * than at ordering, which is what makes it worth encoding here.
   */
  async startStack(rpc, hostParams = null) {
    /* Broker-only options ride in the same object the panel already builds, but they are
       none of the foveated host's business — take them out before the RPC so an unknown
       field can never reach its deserializer. */
    const { desktopQuad, ...forHost } = hostParams || {};
    this.brokerOptions = { desktopQuad: Boolean(desktopQuad) };
    hostParams = hostParams ? forHost : null;

    const steps = [];
    const claim = this.claimRuntime();
    steps.push({ step: 'OpenXR runtime', ok: claim.ok, detail: claim.detail });
    if (!claim.ok) return { ok: false, steps };

    const fail = async () => {
      await this.stopStack(rpc);
      return { ok: false, steps };
    };

    const host = await rpc('FoveatedStart', hostParams).catch((e) => ({ ok: false, detail: e.message }));
    steps.push({ step: 'foveated host', ok: Boolean(host && host.ok), detail: host && host.detail });
    if (!host || !host.ok) return fail();

    const runtime = await rpc('FoveatedStartRuntime', null).catch((e) => ({ ok: false, detail: e.message }));
    steps.push({ step: 'CloudXR runtime', ok: Boolean(runtime && runtime.ok), detail: runtime && runtime.detail });
    if (!runtime || !runtime.ok) return fail();

    /* "Started" means the request was accepted, not that the runtime is reachable — its
       Monado IPC pipe appears some time afterwards, and a broker that starts first dies
       instantly with xrCreateInstance -51. Encoding the order was not enough; the wait has
       to be here too. Observed 2026-07-28: the pipe was still absent when the broker
       started, so there was no PCVR host at all, and the only visible symptom was the
       headset failing to connect with an opaque 0x80086038 and re-asking for a QR code. */
    const ipc = await waitForCloudXrPipe(15000);
    steps.push({
      step: 'CloudXR IPC',
      ok: ipc.ok,
      detail: ipc.ok
        ? `ready in ${ipc.waitedMs} ms`
        : 'the CloudXR runtime never published its IPC pipe; the broker would fail to start. '
          + 'Check the CloudXR service in logs\\cxr-service.log.',
    });
    if (!ipc.ok) return fail();

    const broker = await this.startChecked('broker');
    steps.push({ step: 'session broker', ok: broker.ok, detail: broker.detail });
    if (!broker.ok) return fail();

    // The sidecar attaches to the running CloudXR service, so it goes last and its failure
    // is not fatal to a session — you lose the sidecar, not the stream.
    const gaze = await this.startChecked('sidecar');
    steps.push({ step: 'sidecar', ok: gaze.ok, detail: gaze.detail });
    return { ok: true, steps };
  }

  /**
   * Show or hide the desktop panel in the headset, while a session is running.
   *
   * Also remembered, so the state survives a restart of the stack: the switch means "I
   * want the desktop there", not "poke the broker once", and having it come back off
   * after every restart would be its own small annoyance.
   */
  async setDesktopQuad(enabled) {
    const wanted = Boolean(enabled);
    this.brokerOptions = { ...this.brokerOptions, desktopQuad: wanted };
    if (!this.status().broker.running) return { ok: true, enabled: wanted, applied: false };
    const reply = await requestBrokerControl(`desktop-quad ${wanted ? 'on' : 'off'}`);
    if (!reply.ok) {
      throw new Error(reply.reason
        ? `the session broker refused: ${reply.reason}`
        : 'the session broker refused the request');
    }
    return { ok: true, enabled: Boolean(reply.enabled), applied: true };
  }

  /**
   * Take the stack down in reverse. The broker must stop **before** CloudXR: bouncing
   * CloudXR under a live broker sends it into a log spin that has reached 12 GB.
   */
  async stopStack(rpc) {
    let brokerGameStopError = null;
    let brokerStoppedGame = false;
    if (this.status().broker.running) {
      try {
        const stopped = await requestBrokerControl('stop-active-client');
        if (!stopped.ok) {
          throw new Error(
            `broker could not terminate active game`
            + (stopped.pid ? ` (pid ${stopped.pid})` : '')
            + (stopped.error ? `, Windows error ${stopped.error}` : ''));
        }
        brokerStoppedGame = Boolean(stopped.hadClient);
        if (brokerStoppedGame) this.emit('log', `Active PCVR game stopped (pid ${stopped.pid})`);
      } catch (e) {
        brokerGameStopError = e;
        this.emit('log', `Could not stop the active PCVR game: ${e.message}`);
      }
    }

    let launchedGameStopError = null;
    let launchedGameStopped = false;
    try {
      const stopped = await rpc('GamesStopLaunched', null);
      launchedGameStopped = Boolean(stopped && stopped.hadGame && stopped.ok);
      if (launchedGameStopped && !brokerStoppedGame) {
        this.emit('log', `Launched PCVR game stopped (pid ${stopped.pid})`);
      }
      if (stopped && !stopped.ok) {
        throw new Error(
          `backend could not terminate launched game`
          + (stopped.pid ? ` (pid ${stopped.pid})` : '')
          + (stopped.error ? `: ${stopped.error}` : ''));
      }
    } catch (e) {
      launchedGameStopError = e;
      this.emit('log', `Could not stop the launched PCVR game: ${e.message}`);
    }

    await this.stopAndWait('sidecar');
    await this.stopAndWait('broker');
    // A one-shot's recorded success must not outlive the stack it was part of, or the UI
    // keeps reporting the hook as installed after CloudXR has gone away with it.
    for (const [name, definition] of Object.entries(this.definitions)) {
      if (definition.oneShot) this.exits.delete(name);
    }
    await rpc('FoveatedStop', null).catch(() => null);
    this.releaseRuntime();
    const gameStopError =
      launchedGameStopError && !brokerStoppedGame
        ? launchedGameStopError
        : brokerGameStopError && !launchedGameStopped
          ? brokerGameStopError
          : null;
    if (gameStopError) {
      return {
        ok: false,
        stopped: true,
        detail: `PCVR stopped, but the active game could not be closed: ${gameStopError.message}`,
      };
    }
    return { ok: true };
  }

  /** Kill everything we started. Called on app quit. */
  shutdown() {
    this.shuttingDown = true;
    for (const name of this.restartTimers.keys()) this.#cancelRestart(name);
    for (const name of this.running.keys()) this.stop(name);
    // Synchronous fallback for startup failures and unexpected shutdown paths. The normal
    // close path awaits stopStack() before calling this.
    this.releaseRuntime();
  }
}

module.exports = { Supervisor, resolveCloudXrRuntimeJson };
