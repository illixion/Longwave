'use strict';

const titles = {
  screen: 'See the screen',
  input: 'Control this PC (pointer, keys, typing)',
};

const title = document.getElementById('title');
const code = document.getElementById('code');
const grants = document.getElementById('grants');
const approve = document.getElementById('approve');
const decline = document.getElementById('decline');
let current = null;

function render(request) {
  current = request;
  if (!request) return;
  title.textContent = `Pair “${request.deviceName}” with this PC?`;
  code.textContent = request.code.length === 6 ? `${request.code.slice(0, 3)} ${request.code.slice(3)}` : request.code;
  grants.replaceChildren(...request.offered.map((grant) => {
    const label = document.createElement('label');
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = grant;
    box.checked = request.requested.includes(grant);
    label.append(box, document.createTextNode(titles[grant] || grant));
    return label;
  }));
  approve.disabled = false;
  decline.disabled = false;
  approve.focus();
}

function answer(approved) {
  if (!current) return;
  approve.disabled = true;
  decline.disabled = true;
  const chosen = [...grants.querySelectorAll('input:checked')].map((box) => box.value);
  window.devicePairing.answer(current.id, approved, chosen);
}

approve.addEventListener('click', () => answer(true));
decline.addEventListener('click', () => answer(false));
window.devicePairing.onState(render);
