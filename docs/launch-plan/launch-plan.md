# Vireo — Launch Plan

> A free, native macOS markdown editor that hides the syntax even while you edit.
> Solo/indie launch. No monetization — the goal is **installs, word-of-mouth, and
> a beachhead reputation** in the Mac + AI-dev communities, not revenue.

---

## 1. The one thing to get right

Vireo is a *show, don't tell* product. The entire pitch is visual: **one `.md`
file, open in Vireo vs. open in a raw editor — one shows `## Notes`, the other
shows a heading.** Every asset, post, and the video should lead with that reveal.
If someone sees the before/after in three seconds, the product sells itself.

**Positioning line (use everywhere, lightly varied per channel):**
> Your agent writes markdown all day. Vireo is the fast, native Mac app that
> finally lets you *read* it — syntax hidden, even while you edit. Plain `.md`,
> ~4 MB, free.

**Three proof points that travel well:**
1. **Syntax is gone, not toggled** — no preview pane, invisible while you type, still `.md` on disk.
2. **~4 MB native Swift** vs. Electron apps at 100×+ the footprint. Opens instantly.
3. **Free, no account, no vault, no subscription.** Your files stay plain `.md`.

---

## 2. Pre-launch checklist (assets that MUST be ready)

Nothing ships until these exist. A launch dies if the download 404s or the demo
doesn't load.

- [ ] **Landing page live** on a real domain (not a file://). Fast, dark, the hero screenshot doing the work. (`site/index.html` is the base.)
- [ ] **Notarized `.dmg`** direct download that actually installs clean on a fresh Mac (Gatekeeper-safe). Test on a machine that's never seen the app.
- [ ] **A mirror on GitHub Releases** (devs trust a GitHub release link; also a fallback if the site melts).
- [ ] **The hero before/after image** (Vireo vs raw `##`) as a standalone shareable PNG — this is your single most important marketing asset.
- [ ] **A silent looping demo GIF/MP4** (~6–10s): cursor moving through a doc, syntax staying hidden, the toolbar ⌘B moment. Goes in tweets, Reddit, PH gallery.
- [ ] **The punchy launch video** (see §6). You record it.
- [ ] **OG/Twitter card image** so links unfurl with the before/after, not a blank card.
- [ ] **Lightweight analytics** (Plausible/Umami) + a UTM scheme per channel so you know what actually drove installs.
- [ ] **A short FAQ** ready to paste: "Is it really free? / Why not the App Store? / Windows or Linux? / Is my data private? / How is this different from iA Writer / Obsidian / Typora?"
- [ ] **You, free for ~6 hours on launch day** to answer every comment fast. Response speed *is* the launch.

---

## 3. Channel strategy — where to post & why

Ranked by fit for a **free, visual, native Mac tool with an AI-era angle.**
Tiers = priority + sequencing, not just quality.

### Tier 1 — The launch pillars (do these, they carry the day)

| Channel | Why it's a strong fit | Notes |
|---|---|---|
| **Hacker News — Show HN** | The single best audience for a native, no-Electron, no-subscription dev tool. This crowd *actively resents* 400 MB Electron apps and loves "it's just a text file." | High risk/high reward. Neutral title, honest maker comment, one stated limitation. See post draft. |
| **Product Hunt** | Purpose-built for exactly this kind of launch; strong Mac-app + productivity audience; a badge and lasting SEO/backlink even if you don't hit #1. | Self-hunt is fine in 2026. Tue/Wed 12:01am PT. Never ask for upvotes — ask for comments/feedback. |
| **r/macapps** | *The* home for free/indie Mac app launches. Highly receptive to "I built this, it's free," visual, native. Arguably higher conversion than HN for a Mac-only app. | Strong image/GIF required. Follow the "I made this" flair + self-promo rules. **The best-fit subreddit by far — you didn't list it.** |

### Tier 2 — High-value, do all of them (staggered across the week)

| Channel | Why | Angle to lead with |
|---|---|---|
| **X / Twitter** | Your build-in-public home base and where the AI-dev crowd lives. Not one post — a thread + the video + the before/after. | Agent-era hook. "Claude/Cursor/ChatGPT write markdown all day. Vireo lets you read it." |
| **r/ClaudeAI + r/ChatGPTCoding + r/cursor** | This is the real "AI coding" audience (there is no active **r/AIcoding** — these are where those people actually are). They generate `.md` constantly (READMEs, plans, notes) and feel the pain directly. | "If your agent dumps markdown all day, here's a fast Mac app to actually read it." |
| **r/SideProject** | The friendliest launch sub on Reddit for "I built this." Low risk, supportive. | Build story + the free angle. |
| **r/productivity** | Big, on-topic for a note/markdown tool — but stricter on self-promo. Lead with the workflow, not the download. | "I got tired of reading raw `##` in my notes, so I built…" |
| **LinkedIn** | Your first-degree network + a surprisingly good organic reach for a personal founder story right now. Lower dev-skepticism, higher goodwill. | The founder's-letter angle: *why* you built it. Personal, not salesy. |
| **Lobsters (lobste.rs)** | Small but extremely high-quality dev audience; loves native/minimal tools. **Invite-only to post** — only if you have an account/invite. | Same as Show HN but even more technical. |

### Tier 3 — Directories & long-tail (submit once, they pay off for months via SEO/search)

**Priority order (research-backed): AlternativeTo → Peerlist → Uneed (free) → MicroLaunch (free). Skip BetaList and all paid tiers.**
- **AlternativeTo** — *top priority.* List Vireo as an alternative to Obsidian / Typora / iA Writer / Bear / MacDown. DR ~79, ~700K visits/mo, evergreen "Obsidian alternative" SEO. (Make an account, wait ~a week, then "Suggest new application.")
- **Peerlist Launchpad** — real weekly launch platform, tech-professional audience, kind to indies. Joins the next Monday cohort.
- **Uneed** ( uneed.best ) — friendly PH-style directory, dofollow link, indie-favorable. Free tier is fine.
- **MicroLaunch / Fazier / StartupBase** — batch-submit free tiers; each is a backlink + trickle. Low effort.
- **BetaList — skip.** It excludes already-launched products, so you're disqualified once the app is public. Don't waste time.
- **GitHub "awesome" lists** — PR Vireo into `awesome-mac`, `awesome-markdown`, `awesome-macos-apps`. Evergreen dev discovery. Do this.
- ⚠️ Reality check: makers rarely attribute meaningful traffic to any *single* directory, and Google's 2025 spam updates target thin directory-link schemes. Treat these as cheap, set-and-forget long-tail — not a growth engine.
- **dev.to / Hashnode** — cross-post a *build story* ("How I made an NSTextView hide markdown syntax with null glyphs"). This is content marketing, not a launch post — it's genuinely interesting engineering and pulls the HN/dev crowd. High upside, reusable.

### Tier 4 — Press & newsletters (email a few, low cost, occasional big payoff)

Free indie Mac apps *do* get picked up here — but only two of these are actually built to surface unknown indie apps. Prioritize those; the rest are long shots.

**Best odds (pitch these first, ~1 week before launch):**
- **9to5Mac "Indie App Spotlight"** — *your single best press target.* It's a weekly series by indie dev **Michael Burkhardt** that covers free + paid indie apps and explicitly invites submissions. Email **michaelb@9to5mac.com** directly (not the generic tips@). Subject line: app name + "macOS" + the one-line hook. Include the before/after screenshots and download link.
- **Indie Dev Monday** — active cross-platform newsletter that covers free apps. Pitch **newsletter@indiedevmonday.com**.

**Long shots (one cheap, personal email each — don't count on them):**
- **MacStories** (Club MacStories "App Debuts") — high bar, only personally-tested apps, no paid coverage; cold-pitch Viticci/Voorhees only once you have traction.
- **Six Colors** (jsnell@sixcolors.com) — Apple-industry commentary, no indie feature, but occasionally links things they personally like. Never accepts money/gifts.
- **The Sweet Setup**, **AppleInsider/iMore tips lines** — editorially curated, no open pitch; low odds.

**Pitch format:** 3 sentences + the before/after GIF + download link. Personal, no press-release voice. Send *after* HN/PH so you can cite traction ("hit the HN front page / #X on Product Hunt"). Most solo apps get no top-tier coverage — 9to5Mac's Spotlight and r/macapps are the two channels that actually exist to find unknowns, so weight your effort there.

### Channels you listed — my honest take

| You suggested | Verdict |
|---|---|
| **LinkedIn** | ✅ Yes — founder-story angle. Keep. |
| **Twitter/X** | ✅ Yes, obvious. Make it a thread + video, not one tweet. |
| **HN Show HN** | ✅ Yes — top pillar. |
| **Product Hunt** | ✅ Yes — top pillar. |
| **r/entrepreneur** | ⚠️ Weak fit + strict self-promo rules. This is a free tool, not a business story; audience isn't your user. **Skip**, or only post a *lessons-learned build story* later, not a launch. |
| **r/ChatGPT** | ⚠️ Huge but wrong-shaped audience + aggressive mod removal of tool promo. Low relevance (it's not a ChatGPT product). **Skip** in favor of r/ClaudeAI / r/ChatGPTCoding. |
| **r/AIcoding** | ❌ Not a meaningfully active sub. Redirect that energy to **r/ChatGPTCoding, r/ClaudeAI, r/cursor**. |

**Biggest gap in your list: r/macapps and AlternativeTo.** For a free Mac-only
app those two may out-convert everything except HN.

---

## 4. Paid marketing — my recommendation

**Short version: don't spend on broad Twitter/X promoted posts. For a free tool,
paid social almost never beats a good organic launch — you'd be buying
impressions, not the trust that actually drives a "download a random .dmg"
decision.**

If you want to spend a *little* (say $100–$400), in priority order:

1. **One small, *audience-matched* newsletter slot** — a single shoutout that
   reaches the right people comes with borrowed trust that promoted impressions
   never buy. **Critical caveat:** the obvious dev newsletters (iOS Dev Weekly
   ~$1,800/issue, This Week in Swift ~$399) reach Apple *developers* — people who
   *build* apps, not necessarily people who *read markdown all day*. That's a
   targeting mismatch. A $100–300 slot in a smaller **writing / note-taking /
   productivity** newsletter is a better fit than a pricier dev one. Line it up
   *after* you have HN/PH traction to cite.
2. **Skip X/Twitter promoted posts.** New ad accounts pay a ~2-week "trust
   premium" (guides say budget $300–500 just to warm the account up), and ads
   need ~1M+ impressions to mean anything — a small budget is eaten by the
   platform learning, not buying reach. Your build-in-public thread + fast replies
   will outperform it dollar-for-dollar.
3. **Skip Reddit Ads too.** First-person indie postmortems are brutal for niche
   software ($100 → 247 clicks / 0 conversions; $3,200 → 4 customers, ~50%
   fraudulent clicks). The *same* makers' **organic** r/macapps posts beat their
   paid spend every time. For a free app, an organic r/macapps post > any Reddit
   ad. *(I'd previously have suggested a small Reddit test — the data says don't.)*

**Verdict: with no revenue to recoup, spend $0 on ads and let the launch be
organic — a free, screenshot-obvious Mac app is the *ideal* organic-launch
candidate. If you spend anything at all, make it one small, audience-matched
(writing/productivity, not dev-tooling) newsletter slot, placed *after* you have
HN/PH numbers to point to.**

---

## 5. Recommended launch sequence (don't fire everything at once)

Spacing channels out avoids looking spammy, lets you carry momentum from one to
the next, and gives you traction to cite in later pitches.

**T-1 to 2 weeks — Prime the pump**
- Build in public on X **and Bluesky** (Bluesky doesn't throttle outbound links — 3–4× better link-referral than X, which matters for a download link): 2–3 posts showing the before/after and the "syntax hidden while editing" magic. Tease a date. This also means you're not a cold account on launch day.
- ~~Product Hunt "Coming Soon" page~~ — **PH discontinued teaser/Coming-Soon pages in Aug 2025. Don't build one.** Collect notify-me's on your own landing page instead.
- Submit to **AlternativeTo** now (it's evergreen, not launch-day-gated) and get into the next **Peerlist** weekly cohort + **Uneed** free queue.
- Email the press shortlist ~1 week ahead (see §3 Tier 4 for the actual contacts).
- Get the landing page + download bulletproof. Line up any Lobsters invite.

**Launch Day (a Tuesday or Wednesday)**
1. **12:01am PT — Product Hunt** goes live. Post your maker's first comment (the "why"). Share the *link to your PH page* (not "please upvote") with your list/X followers.
2. **~6–9am ET — Show HN** goes up (Tue–Thu morning is prime). Immediately post the honest maker comment. Then **sit on it for an hour** replying to everything.
3. **Late morning — X launch thread** (video + before/after GIF + link). Pin it.
4. **Midday — r/macapps** post (image-led). 
5. **Afternoon — LinkedIn** founder-story post.
> Don't do all the Reddit subs the same day. **One subreddit per day** afterward.

**Launch Week (days 2–5) — one channel per day**
- Day 2: r/SideProject
- Day 3: r/ClaudeAI *or* r/ChatGPTCoding (pick the better-fit framing)
- Day 4: r/productivity (workflow-led, soft)
- Day 5: r/cursor, plus submit to AlternativeTo / Uneed / Peerlist / awesome-lists.

**Post-launch (week 2+)**
- Email the press/newsletter shortlist **with your HN/PH numbers as proof**.
- Publish the dev.to/Hashnode engineering build-story (null-glyph syntax hiding) — a second, slower wave of the *right* audience.
- If spending: place the newsletter shoutout now.

**Golden rules**
- Never ask for upvotes anywhere (bannable on PH & HN; kills you on Reddit). Ask for feedback.
- One honest limitation stated up front earns more trust than any feature list.
- Reply to *every* comment for the first few hours on each channel.
- Tailor each post to the platform's voice (drafts in `/posts`). Never paste the same text everywhere — cross-posting identical copy is the fastest way to get flagged.

---

## 6. Launch video — spec & script (you record, for authenticity)

**Format:** 20–35 seconds. Vertical *and* landscape export (vertical for
Reddit/X/TikTok-style, landscape for PH/YT/site embed). Screen recording with a
short optional talking-head bookend. No music bed required — a clean screen +
your voice is more authentic and more "indie dev" than a polished ad.

**Why it's worth the effort:** Product Hunt launches *with* a video average ~384
upvotes vs ~167 without — more than double. The video isn't a nice-to-have; it's
the highest-leverage asset after the before/after image, and it's reusable across
PH, X, Bluesky, Reddit, and the site.

**The core idea:** the whole video is the *reveal*. Don't explain features — show
the before/after and let the "oh, the syntax is just… gone" land.

**Shot list / script:**

1. **(0:00–0:04) The hook — split screen.** Same `.md` file open in a raw editor (left, full of `##`, `**`, `- [ ]`) and in Vireo (right, clean document). Your VO: *"This is the same markdown file. On the left, what your editor shows you. On the right, Vireo."*
2. **(0:04–0:12) The magic — editing with syntax hidden.** Screen-record yourself *typing* in Vireo: type `**bold**` and it just becomes **bold** live, no asterisks ever visible. Add a heading, check a checkbox. VO: *"The syntax never shows up — even while you're typing it. It's still a plain `.md` file underneath."*
3. **(0:12–0:20) The flex — speed + size.** Quick cut: double-click a `.md` in Finder, Vireo opens instantly. Optional: Activity Monitor showing ~a few MB. VO: *"Native Swift. About four megabytes. It opens before other editors finish launching."*
4. **(0:20–0:30) The turn — the "why."** Talking head or plain text card. VO: *"Your agent writes markdown all day. I just wanted to read it like a document. No vaults, no plugins, no subscription. It's free."*
5. **(0:30–0:33) CTA card.** "Vireo — markdown, without the markup. Free for Mac. [domain]" + Apple logo.

**Recording tips:** clean desktop, hide personal files, dark mode (matches the
brand), 60fps screen capture, cursor visible, real content (a plausible README or
notes doc — not lorem ipsum). Keep your VO conversational, one take, slightly
imperfect > over-produced.

---

## 7. Metrics — how you'll know it worked

- **Installs / DMG downloads** (the only number that matters), attributed by UTM per channel.
- HN: front page? points, comments. PH: rank, upvotes, comments. Reddit: upvotes + save ratio.
- Landing-page visits → download conversion rate per source.
- Qualitative: what objection keeps recurring in comments? That's your next landing-page edit and your v2 FAQ.

---

## 8. Open questions for you

- Is the notarized `.dmg` + landing domain actually ready, or is prep part of this plan's timeline?
- Do you have a Lobsters account/invite? (gates that channel)
- Any existing X/LinkedIn following to seed the launch, or starting cold?
- Comfortable stating one honest current limitation publicly (macOS-only, no Windows, feature not-yet-X)? It materially helps on HN.
