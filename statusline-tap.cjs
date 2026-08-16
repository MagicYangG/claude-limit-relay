#!/usr/bin/env node
// statusline-tap: transparent pipe stage for the Claude Code statusLine.
//
// stdin is forwarded to stdout VERBATIM (byte-identical), so it can sit in
// front of any existing statusline command without changing what it renders.
// Side effect: the payload's rate_limits block (the only documented
// machine-readable source of the 5h/weekly usage windows) is cached next to
// this file as state-ratelimits.json, where relay.ps1 reads it to time its
// probes precisely instead of polling blind.
//
// --solo: no downstream statusline - render a minimal usage line instead of
// echoing the payload (for users who had no statusLine configured at all).
//
// Install / remove:  relay statusline on | off
'use strict';
const fs = require('fs');
const path = require('path');

const solo = process.argv.includes('--solo');
const chunks = [];
process.stdin.on('data', function (c) { chunks.push(c); });
process.stdin.on('end', function () {
  const buf = Buffer.concat(chunks);
  let payload = null;
  try { payload = JSON.parse(buf.toString('utf8')); } catch (e) { /* forward regardless */ }

  if (payload && payload.rate_limits) {
    // atomic-ish: temp + rename, last writer wins across concurrent sessions
    const dest = path.join(__dirname, 'state-ratelimits.json');
    const tmp = dest + '.tmp-' + process.pid;
    try {
      fs.writeFileSync(tmp, JSON.stringify({
        capturedAt: new Date().toISOString(),
        rate_limits: payload.rate_limits
      }));
      fs.renameSync(tmp, dest);
    } catch (e) {
      try { fs.unlinkSync(tmp); } catch (e2) { /* never break the statusline */ }
    }
  }

  if (solo) { process.stdout.write(renderSolo(payload)); return; }
  process.stdout.write(buf);
});

function toDate(v) {
  if (v == null) return null;
  if (typeof v === 'number') return new Date(v > 1e12 ? v : v * 1000);
  const d = new Date(String(v));
  return isNaN(d.getTime()) ? null : d;
}

function two(n) { return (n < 10 ? '0' : '') + n; }

function renderSolo(j) {
  try {
    const parts = [];
    if (j && j.model && j.model.display_name) parts.push(j.model.display_name);
    const rl = (j && j.rate_limits) ? j.rate_limits : {};
    const seg = function (label, o) {
      if (!o) return;
      const pct = (o.utilization != null) ? o.utilization : o.used_percentage;
      let s = label + ' ' + (pct != null ? Math.round(pct) + '%' : '?');
      const d = toDate(o.resets_at);
      if (d) s += '→' + two(d.getHours()) + ':' + two(d.getMinutes());
      parts.push(s);
    };
    seg('5h', rl.five_hour);
    seg('wk', rl.seven_day);
    return parts.join(' · ') || 'claude';
  } catch (e) { return 'claude'; }
}
