'use strict';

const code = document.getElementById('code');
const qr = document.getElementById('qr');
const instructions = document.getElementById('instructions');

function render(state) {
  const revealed = Boolean(state?.available && state.revealed && state.qrPngDataUri);
  code.classList.toggle('masked', !revealed);
  code.disabled = !state?.available;
  code.setAttribute('aria-label', revealed ? 'Mask pairing code' : 'Reveal pairing code');
  instructions.textContent = state?.available
    ? (revealed ? 'Scan this code with Vision Pro.' : 'Click the masked code when you are ready to scan.')
    : 'Pairing is no longer required. You can close this window.';
  if (revealed) qr.src = state.qrPngDataUri;
  else qr.removeAttribute('src');
}

code.addEventListener('click', () => window.pairing.toggleReveal());
window.pairing.onState(render);
