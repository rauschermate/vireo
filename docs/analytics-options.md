# Analytics options for Vireo

Research + decision guide for measuring Vireo across its two surfaces — the
marketing site (`site/index.html`) and the native macOS app — with a bias toward
Vireo's "simple, private, no-subscription" ethos.

> Status: research only. Nothing is wired up yet. The last section proposes a
> small rollout.

## Start here: what do you actually want to measure?

Three very different questions, three very different amounts of work:

| Question | Where it's measured | Effort |
|---|---|---|
| **1. How many people download it?** | Your host (GitHub) — **no app code** | ~zero |
| **2. How many people actively use it (DAU/MAU)?** | **Only the app can report this** (a launch ping) | small |
| **3. What do they do in it / does the site convert?** | Site + app product analytics | medium |

Pick the lowest number that answers your question — you don't need #2's tooling to
answer #1, and you don't need #3 to answer #2.

---

## 1. Downloads — no app code needed

A download happens on the host before the app ever runs, so the app can't measure
it (the app only sees *launches/installs*, a smaller number).

### GitHub release download counts (free, already set up)
`scripts/release.sh` uploads `Vireo.dmg` as a GitHub Release asset, and GitHub
counts every asset download automatically:

```bash
gh api repos/rauschermate/vireo/releases --jq '.[].assets[] | {name, download_count}'
```
(Empty until the first release is published.) This is the closest thing to a true
download count and needs nothing else.

### The Sparkle caveat (important)
Because the auto-updater downloads the DMG over the same URL GitHub counts, the
DMG's `download_count` becomes **installs + auto-updates**, not "new users":
- Inflated by *actual updates*, but **not** by update *checks* — Sparkle hits
  `appcast.xml` hourly but only fetches the DMG when a user actually updates.
- The **`appcast.xml` asset's** own `download_count` is pure noise (every client,
  every hour) — ignore it.
- Each version's DMG count ≈ new installs of that version + everyone updating to
  it (the appcast always points clients at the newest release).

### Cleaner "new-user acquisition" → website `download_clicked`
A website-only PostHog event on the download button measures **clicks from the
landing page**, excluding Sparkle's update traffic by construction. It's a click
(not a completed download) and ad blockers undercount it without a proxy — but for
"how many *new* people are we acquiring," it's the less-polluted signal.

```html
<a href="/download/Vireo.dmg"
   onclick="posthog.capture('download_clicked', { source: 'hero' })">
  Download for macOS
</a>
```

**Bottom line:** GitHub count for the gross total; site `download_clicked` if you
want new-user acquisition specifically. No in-app analytics required for either.

---

## 2. Active usage — DAU / MAU (needs an in-app ping)

DAU/MAU is *active usage*, which only the app can report by pinging home on launch.
GitHub counts and web analytics cannot see it.

### The one unavoidable concept: identity
To count **unique** actives (not just launches) you need an identifier stable
enough to dedupe a device across the day/month. That's the single bit of "identity"
no MAU tool can skip. Privacy-first approaches use a **random per-install id** or a
**salted hash**, so individuals aren't trackable externally but uniques are
countable. Key subtlety: for **MAU the id must be stable across the month** — a
*daily-rotating* salt (a web-visitor trick) gives DAU but makes MAU impossible.

### Tool comparison (for DAU/MAU on a macOS Swift app)

| Option | DAU/MAU? | Fit for a privacy-branded Mac app | Effort |
|---|---|---|---|
| **TelemetryDeck** | ✅ + retention | **Best fit** — Swift SDK (macOS/iOS/…), cookieless, EU/Germany-hosted, GDPR, built for Apple-platform indies | Low |
| **PostHog** | ✅ + funnels/flags/experiments | Good if you want **one tool for site *and* app** and room to grow | Low–med |
| **Aptabase** | ❌ **No MAU/retention** | Privacy-lovely, but stores *no* per-user id by design → can't do MAU. Wrong tool for this goal | — |
| **DIY launch ping** | ✅ (you compute it) | Max control/privacy, zero vendors | Medium |
| Firebase / GA | ✅ | **Avoid** — Google, privacy-hostile, weak macOS support | — |
| Apple App Store analytics | — | **N/A** — Vireo ships a direct DMG, not via the App Store | — |

**Recommendation:** **TelemetryDeck** if you want just usage with minimal code and
maximum on-brand privacy; **PostHog** if you'd rather one tool spanning site + app;
**DIY** if you want zero third parties.

### DIY design (zero vendors) — what it looks like

Four small pieces: a launch ping in the app, a Cloudflare Worker, a D1 table, and
SQL that turns rows into DAU/MAU.

```
Vireo (macOS)  ──POST /ping (once/day)──▶  Cloudflare Worker  ──INSERT──▶  D1 (SQLite)
                                                                              │
                    you  ──SQL: DAU / MAU / version split───────────────────◀┘
```

**a) App — the launch ping (Swift).** Anonymous, opt-out-gated, dev-guarded,
throttled to once per UTC day:

```swift
enum Analytics {
    static let endpoint = URL(string: "https://ping.vireo.app/ping")!

    static func pingIfNeeded() {
        guard Preferences.shared.usageStatsEnabled else { return }   // Preferences toggle
        #if DEBUG
        return                                                       // don't count dev runs
        #endif
        let today = dayKey()                                         // "2026-07-12" (UTC)
        guard UserDefaults.standard.string(forKey: "lastPingDay") != today else { return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": installID(),                                       // random per-install UUID
            "v":  Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        ])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                UserDefaults.standard.set(today, forKey: "lastPingDay")
            }
        }.resume()                                                   // fire-and-forget
    }

    /// Anonymous, random, per-install — NOT hardware-derived (so it's not PII and
    /// can't be correlated across apps). Resets if the user clears app data.
    private static func installID() -> String {
        let k = "analyticsInstallID"
        if let v = UserDefaults.standard.string(forKey: k) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: k)
        return v
    }
    private static func dayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .init(identifier: "UTC")
        return f.string(from: Date())
    }
}
```
Call `Analytics.pingIfNeeded()` from `applicationDidFinishLaunching` (next to where
the updater starts).

**b) Cloudflare Worker — the endpoint.** Never stores the raw id or the IP; stores a
salted SHA-256 so a DB leak can't be correlated externally:

```js
export default {
  async fetch(req, env) {
    if (req.method !== "POST") return new Response("ok");
    const { id, v, os } = await req.json().catch(() => ({}));
    if (!id) return new Response("bad", { status: 400 });

    const day  = new Date().toISOString().slice(0, 10);          // UTC YYYY-MM-DD
    const hash = await sha256(id + env.SALT);                    // env.SALT = fixed secret

    await env.DB.prepare(
      "INSERT OR IGNORE INTO active (hash, day, app_version, os) VALUES (?,?,?,?)"
    ).bind(hash, day, String(v ?? ""), String(os ?? "")).run();  // OR IGNORE dedupes re-pings

    return new Response("ok");
  }
};
async function sha256(s) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, "0")).join("");
}
```

**c) D1 — the schema.** The composite primary key does the DAU dedup:

```sql
CREATE TABLE active (
  hash        TEXT NOT NULL,   -- salted hash of the install id
  day         TEXT NOT NULL,   -- 'YYYY-MM-DD'
  app_version TEXT,
  os          TEXT,
  PRIMARY KEY (hash, day)      -- re-pings on the same day collapse to one row
);
CREATE INDEX idx_active_day ON active(day);
```

**d) Compute DAU / MAU — just SQL:**

```sql
-- DAU today
SELECT COUNT(*) AS dau FROM active WHERE day = date('now');

-- DAU, last 30 days
SELECT day, COUNT(*) AS dau FROM active
WHERE day >= date('now','-29 days') GROUP BY day ORDER BY day;

-- MAU = unique devices active in the trailing 30 days
SELECT COUNT(DISTINCT hash) AS mau FROM active
WHERE day >= date('now','-29 days');

-- Version adoption (ties into the Sparkle updater)
SELECT app_version, COUNT(DISTINCT hash) AS users FROM active
WHERE day >= date('now','-29 days') GROUP BY app_version ORDER BY users DESC;
```
Because `(hash, day)` is unique, `COUNT(*) WHERE day=X` is that day's DAU and
`COUNT(DISTINCT hash)` over a window is MAU.

**Decisions that matter:**
- **Identity/privacy:** fixed `SALT` → stable hash → MAU works, device linkable
  *only inside your own DB* (never externally, raw id never stored). Rotate `SALT`
  monthly for "un-linkable across months" (MAU-within-a-month still works). **Never
  daily** (kills MAU).
- **No PII, ever** — random id, no file names/paths/content, no IP stored.
- **Cost:** effectively free — Workers 100k req/day, D1 5M reads + 100k writes/day;
  a once-per-day ping is nowhere near it.
- **Caveat vs a vendor:** fire-and-forget, no offline queue/retry → a launch with
  no network isn't counted. Fine for trend-level DAU/MAU, not exact accounting.
  (Batching, retries, and dashboards are exactly what TelemetryDeck/PostHog add.)

---

## 3. Product analytics (PostHog) — site + app

If you want more than counts — funnels, retention, feature adoption, replay, flags,
A/B tests — PostHog covers both surfaces from one project.

### How it works (mental model)
- **Events** are the atom: `capture("name", props)`, tied to an anonymous
  `distinct_id`. **Insights** (trends/funnels/retention/paths/cohorts) sit on top.
- **Autocapture** (clicks/pageviews without per-element code) works on **web and
  iOS — not macOS**.
- Same project also has **web analytics** (GA4-style), **session replay** (web +
  mobile, *not macOS*), **feature flags** + **experiments**, **surveys**, **error
  tracking**.
- **Hosting:** US (Virginia) or **EU (Frankfurt)** — pick EU for GDPR; effectively
  permanent. **Free tier (no card):** 1M analytics events, 5k web replays (2.5k
  mobile), 1M flag requests, 100k error-tracking exceptions, 1.5k surveys / month.

### Website (`site/index.html`)
Single static file → easiest target. Paste the `posthog-js` snippet in `<head>`
(project API key is public/safe to commit), and you get web analytics + autocapture
+ web session replay for free. Add the `download_clicked` event (above) for the
conversion funnel. **Use PostHog's free managed reverse proxy** (one CNAME) or ad
blockers eat 10–30% of events.

```html
<script>
  /* posthog-js loader snippet */
  posthog.init('phc_YOURPROJECTKEY', {
    api_host: 'https://ph.vireo.app',        // reverse-proxy subdomain
    ui_host: 'https://eu.posthog.com',
    person_profiles: 'identified_only',
    autocapture: true, capture_pageview: true
  });
</script>
```

### App (native macOS)
The `PostHog` Swift SDK (`github.com/PostHog/posthog-ios`, latest `3.64.1`) supports
**macOS 10.15+**, ships a `PrivacyInfo.xcprivacy`, and does crash reporting on
macOS. **But no session replay and no autocapture on macOS** — every event is
hand-instrumented. Keep it a deliberate ~6-event set, not a firehose:

```swift
import PostHog
let config = PostHogConfig(apiKey: "phc_YOURPROJECTKEY", host: "https://eu.posthog.com")
config.captureApplicationLifecycleEvents = true   // app opened/backgrounded → DAU/MAU
PostHogSDK.shared.setup(config)
```

| Event | Why |
|---|---|
| `app_launched` (lifecycle) | DAU/WAU, retention base |
| `document_opened` | activation (property `source`; **never the path**) |
| `document_saved` | deeper activation |
| `feature_used` | adoption (`feature` = bold/table/focus_mode/toc/find/zoom…) |
| `update_pill_shown` / `_clicked` / `update_dismissed` | **update-adoption funnel** for the Sparkle updater |
| `error` (error tracking) | crash/exception rate per version |

### Insights you'd get
- **Web:** where visitors come from, visit→download conversion, A/B the headline,
  replay confused sessions.
- **App:** activation (open+edit in session 1), **day-1/7/30 retention** (the key
  number), which features drive retention, **update-rollout speed**, version/crash
  distribution.

### Cross-platform identity (limit)
A web visitor and an app user get **different anonymous ids** with no clean join
(the download is a static file, not an authenticated handoff). Treat web and app as
**two separate funnels** — stitching them is fragile and privacy-hostile for a
no-account app.

---

## Privacy principles (apply to every option above)

Vireo is sold as quiet, local, no-subscription — analytics must not betray that:
- **Never** capture document **content, file names, folder paths, or URLs**.
- Add a **Preferences ▸ "Share anonymous usage data" toggle** (opt-out minimum;
  opt-in is more on-brand) and gate all telemetry on it.
- **Disable analytics in DEBUG / unsigned builds** (same spirit as the updater's
  dormant-unless-configured guard) so dev runs don't pollute data.
- Prefer the **EU region**; ship the SDK's **`PrivacyInfo.xcprivacy`**; publish a
  short **privacy policy** linked from the site + About window.
- The **project/public key** is safe to ship; the **personal API key** is secret —
  never bundle it. Set a **billing limit** so a spike can't surprise-bill.

---

## Recommendation

- **Downloads:** GitHub release `download_count`. Done — no app code.
- **New-user acquisition from the site:** website-only PostHog with a
  `download_clicked` event (+ reverse proxy).
- **DAU/MAU/retention:** **TelemetryDeck** (least code, most on-brand) *or* the
  **DIY ping** (zero vendors) *or* **PostHog** if you also want funnels/flags and a
  single tool across site + app.
- Whichever: opt-out toggle, no PII/paths/content, dev-build guard, EU region.

### Suggested rollout (small, reversible)
1. **Site (½ day):** create the project (EU), managed reverse proxy, snippet +
   `download_clicked`. Zero app risk.
2. **App opt-out plumbing (½ day):** Preferences toggle + a `VireoAnalytics` wrapper
   that no-ops when disabled or in dev builds — *before* capturing anything.
3. **App usage (½ day):** whichever tool for DAU/MAU (+ the update-pill funnel if
   PostHog). Verify events land in a live view.
4. **Dashboards + a privacy-policy page.**
