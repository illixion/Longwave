'use strict';

/*
 * A deliberately small markdown renderer, scoped to exactly the constructs
 * THIRD_PARTY_NOTICES.md actually uses: headings, paragraphs, rules, tables,
 * ordered and unordered lists, emphasis, inline code and links.
 *
 * Why not a markdown library, or a hand-written HTML twin of the file: a licence page
 * that has drifted from the notices it claims to mirror is a false compliance claim, so
 * there has to be one source. Between adding a dependency to render it and writing the
 * ~80 lines that cover what we write, the lines are cheaper to audit — and this page is
 * one of the few in the app where being able to audit it is the point.
 *
 * Everything is escaped before any markup is introduced, so the notices file cannot
 * inject HTML into this window even though it is content we ship rather than content a
 * user supplies.
 */

const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
const escapeHtml = (s) => s.replace(/[&<>"]/g, (c) => ESCAPES[c]);

/** Heading text -> GitHub-style anchor, so the in-file "jump to section 2" links work. */
function slug(text) {
  return text.toLowerCase().replace(/[^\w\s-]/g, '').trim().replace(/\s+/g, '-');
}

/** Inline spans. Order matters: code first, so backticked text is not re-scanned. */
function inline(md) {
  const code = [];
  let out = md.replace(/`([^`]+)`/g, (_m, body) => {
    code.push(body);
    return `\u0000${code.length - 1}\u0000`;
  });
  out = escapeHtml(out)
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_m, text, href) => {
      const safe = /^(https?:|#)/i.test(href) ? href : '';
      return safe
        ? `<a href="${escapeHtml(safe)}">${text}</a>`
        : text; // a relative repo path is not reachable from here; show the words only
    })
    // Autolinks: <https://…>. Half the URLs in a notices file are written this way, and a
    // licence page where you cannot reach the upstream project is missing the point.
    // Matched post-escape, so the angle brackets are already &lt; and &gt;.
    .replace(/&lt;(https?:\/\/[^\s&]+)&gt;/g, (_m, url) => `<a href="${url}">${url}</a>`)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
  return out.replace(/\u0000(\d+)\u0000/g, (_m, i) => `<code>${escapeHtml(code[Number(i)])}</code>`);
}

function renderTable(rows) {
  const cells = (line) => line.replace(/^\||\|$/g, '').split('|').map((c) => inline(c.trim()));
  const head = cells(rows[0]).map((c) => `<th>${c}</th>`).join('');
  const body = rows.slice(2)
    .map((r) => `<tr>${cells(r).map((c) => `<td>${c}</td>`).join('')}</tr>`)
    .join('');
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function render(md) {
  const lines = md.split(/\r?\n/);
  const html = [];
  let paragraph = [];
  let list = null; // 'ul' | 'ol'

  const flushParagraph = () => {
    if (paragraph.length) html.push(`<p>${inline(paragraph.join(' '))}</p>`);
    paragraph = [];
  };
  const flushList = () => {
    if (list) html.push(`</${list}>`);
    list = null;
  };
  const flushAll = () => { flushParagraph(); flushList(); };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];

    if (!line.trim()) { flushAll(); continue; }

    if (/^\s*(---|===)\s*$/.test(line)) { flushAll(); html.push('<hr />'); continue; }

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      flushAll();
      const level = heading[1].length;
      const text = heading[2];
      html.push(`<h${level} id="${slug(text)}">${inline(text)}</h${level}>`);
      continue;
    }

    if (line.startsWith('|')) {
      flushAll();
      const rows = [];
      while (i < lines.length && lines[i].startsWith('|')) { rows.push(lines[i]); i += 1; }
      i -= 1;
      if (rows.length >= 2) html.push(renderTable(rows));
      continue;
    }

    const ordered = line.match(/^(\d+)\.\s+(.*)$/);
    const bullet = line.match(/^[-*]\s+(.*)$/);
    if (ordered || bullet) {
      flushParagraph();
      const want = ordered ? 'ol' : 'ul';
      if (list !== want) { flushList(); html.push(`<${want}>`); list = want; }
      html.push(`<li>${inline(ordered ? ordered[2] : bullet[1])}</li>`);
      continue;
    }

    // A continuation line of the current list item, or of a paragraph.
    if (list && /^\s+\S/.test(line) && html[html.length - 1].startsWith('<li>')) {
      html[html.length - 1] = `${html[html.length - 1].slice(0, -5)} ${inline(line.trim())}</li>`;
      continue;
    }
    flushList();
    paragraph.push(line.trim());
  }
  flushAll();
  return html.join('\n');
}

async function main() {
  const doc = document.getElementById('noticesDoc');
  let text;
  try {
    text = await window.notices.read();
  } catch (e) {
    doc.innerHTML = `<p class="hint is-fault">Could not read the notices file: ${escapeHtml(e.message)}</p>`;
    return;
  }
  doc.innerHTML = render(text);

  // External links open in the user's browser; this window never navigates away from the
  // notices, so a mis-click cannot turn the licence page into an uncontrolled web view.
  doc.addEventListener('click', (event) => {
    const anchor = event.target.closest('a[href]');
    if (!anchor) return;
    const href = anchor.getAttribute('href');
    if (href.startsWith('#')) return; // in-page section jump, let it happen
    event.preventDefault();
    window.notices.openExternal(href);
  });
}

main();
