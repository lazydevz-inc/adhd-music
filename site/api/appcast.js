// Serves the signed Sparkle feed (built by Site/build_web.py) and counts one "update_check" per request from the app.
const XML = require('./_appcast-data.js');
const KEY = 'phc_rSmjaBgCTVpeoZ4uNE7SBmyA5mBSHBGUWAxnZKjBFxm3';

module.exports = async (req, res) => {
  const ua = String(req.headers['user-agent'] || '');
  const m = ua.match(/^(.+?)\/(\S+) Sparkle\/(\S+)/);
  if (m) {
    // From 1.0.2 the app adds two rough listening numbers as query items (Sources/App/Updates.swift).
    const q = new URL(req.url || '/', 'https://adhdmusic.app').searchParams;
    const ranges = ['0', '1-29', '30-59', '60-119', '120-239', '240+'];
    const yesterday = ranges.includes(q.get('listen_yesterday')) ? q.get('listen_yesterday') : null;
    const days = /^[0-7]$/.test(q.get('listen_days7') || '') ? Number(q.get('listen_days7')) : null;
    try {
      await fetch('https://us.i.posthog.com/i/v0/e/', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          api_key: KEY,
          event: 'update_check',
          distinct_id: 'check-' + require('crypto').randomUUID(),
          properties: {
            app_version: m[2],
            sparkle_version: m[3],
            country: String(req.headers['x-vercel-ip-country'] || ''),
            listen_yesterday: yesterday,
            listened_yesterday: yesterday === null ? null : yesterday !== '0',
            listen_days7: days,
            $process_person_profile: false,
            $geoip_disable: true,
            $ip: null,
            $lib: 'appcast-function'
          }
        }),
        signal: AbortSignal.timeout(1500)
      });
    } catch (e) { /* counting never blocks the update */ }
  }
  res.setHeader('Content-Type', 'application/xml');
  res.setHeader('Cache-Control', 'no-store');
  res.statusCode = 200;
  res.end(XML);
};
