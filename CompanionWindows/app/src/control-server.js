'use strict';
const net = require('net');

const PIPE_PATH = '\\\\.\\pipe\\visionvnc-companion-control';
const MAX_REQUEST_BYTES = 64 * 1024;

/**
 * Local development RPC owned by the Electron process.
 *
 * The backend pipe cannot safely restart PCVR because Electron owns the broker and its
 * restart policy. This endpoint keeps orchestration with that owner while still allowing
 * foveated-ctl.ps1 to drive it from an SSH shell.
 */
class ControlServer {
  constructor(dispatch, log = () => {}) {
    this.dispatch = dispatch;
    this.log = log;
    this.server = null;
  }

  start() {
    if (this.server) return;
    this.server = net.createServer((socket) => {
      socket.setEncoding('utf8');
      let buffer = '';
      socket.on('data', (chunk) => {
        buffer += chunk;
        if (Buffer.byteLength(buffer, 'utf8') > MAX_REQUEST_BYTES) {
          socket.destroy(new Error('control request exceeded 64 KiB'));
          return;
        }
        let newline;
        while ((newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (line) this.#handleLine(socket, line);
        }
      });
      socket.on('error', (error) => this.log(`control client error: ${error.message}`));
    });
    this.server.on('error', (error) => this.log(`control pipe error: ${error.message}`));
    this.server.listen(PIPE_PATH, () => this.log(`control pipe listening on ${PIPE_PATH}`));
  }

  async #handleLine(socket, line) {
    let request;
    try {
      request = JSON.parse(line);
      if (!request || typeof request.method !== 'string') {
        throw new Error('request needs a method');
      }
      const result = await this.dispatch(request.method, request.params);
      socket.write(`${JSON.stringify({ id: request.id, result })}\n`);
    } catch (error) {
      socket.write(`${JSON.stringify({
        id: request && request.id,
        error: { code: 'CONTROL_ERROR', message: error.message || String(error) },
      })}\n`);
    }
  }

  stop() {
    const server = this.server;
    this.server = null;
    if (!server) return Promise.resolve();
    return new Promise((resolve) => server.close(resolve));
  }
}

module.exports = { ControlServer, PIPE_PATH };
