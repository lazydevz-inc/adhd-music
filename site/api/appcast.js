// Serves the signed Sparkle feed (built by Site/build_web.py) and counts one "update_check" per request from the app.
const XML = require('./_appcast-data.js');
const KEY = 'phc_rSmjaBgCTVpeoZ4uNE7SBmyA5mBSHBGUWAxnZKjBFxm3';

module.exports = async (req, res) => {
  const ua = String(req.headers['user-agent'] || '');
  const m = ua.match(/^(.+?)\/(\S+) Sparkle\/(\S+)/);
  if (m) {
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
