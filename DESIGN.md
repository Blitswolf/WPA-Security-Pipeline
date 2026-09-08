# Pipeline — Distributed WPA Capture → Crack → Research

A self-hosted, authorized-lab pipeline that splits WPA security testing across three machines,
each doing the part it is actually good at. This document is the **design and theory**; the
component code lives alongside it (and in the per-component repos linked below). It reflects the
**current, honest build state** — including what is proven and what is still limited.

> **Authorized use only.** Every component is scoped to the operator's own lab AP (an allow-list
> of BSSIDs). It is a defensive/research tool for networks you own or are explicitly permitted to
> test.

---

## 1. The core idea

Cracking WPA has three very different workloads, and one machine is rarely good at all three:

| Workload | Wants | Bad fit |
|---|---|---|
| **Capture** a 4-way handshake | a radio in monitor mode, patience, RF proximity | a GPU box in a rack |
| **Crack** the handshake | raw compute (GPU ≫ CPU for PBKDF2-SHA1×4096) | a headless Pi |
| **Research** the AP's vulns | a corpus + CPU for inference | anything without the data |

So the pipeline **places each workload on the right host** and moves small artifacts between them:

```
   ┌────────────────────────────┐        ┌────────────────────────────┐
   │  CAPTURE APPLIANCE           │        │  CRACKER + RESEARCHER       │
   │  kali-pie (Raspberry Pi)     │        │  home-pie (Raspberry Pi)    │
   │  • wpacrack --harvest        │  rsync │  • crackstack (aircrack-ng) │
   │    monitor-mode radio,        │ ─────▶ │    markovgen → aircrack      │
   │    scope-locked capture      │  pull  │  • apresearch (exploit-intel)│
   │  • builds a handshake LIBRARY│ ◀───── │    over ssh (pull model)     │
   │  • apvulnd (AP recon)         │        └────────────────────────────┘
   │  • apresearch (exploit model)│
   └────────────────────────────┘        ┌────────────────────────────┐
                 ▲                         │  FAST LANE (optional)       │
                 │  handshake .cap/.22000  │  laptop (RTX 4050 GPU)      │
                 └─────────────────────────│  hashcat -m 22000 -w4 -O    │
                                           │  (orders of magnitude faster)│
                                           └────────────────────────────┘
```

**Key theory — "models need a harness on every host."** The two *models* in this system
(`markovgen` for password candidates, `apresearch` for vuln intelligence) are pure, portable
Python. But a model only produces *inputs*; it needs a working **harness** on its host to do the
actual work:
- `markovgen` emits ordered password candidates → needs a **WPA cracker** to consume them.
- `apresearch` emits ranked hypotheses → needs the **exploit-db corpus** + CPU.

Getting the harness right per host is where most of the engineering (and the surprises) live.

---

## 2. Components

### 2.1 `wpacrack --harvest` — the capture appliance (kali-pie)
Continuous, headless handshake capture into a library.
- Sets monitor mode **once** and holds it (an earlier design that bounced NetworkManager per cycle
  wedged the Pi's SSH — the fix was to stop churning the network stack).
- **Scope-locked**: only the BSSIDs in `wpacrack.conf` are ever captured, and `archive()` *refuses*
  to store any handshake whose BSSID is not on the allow-list — enforced in code, not just by
  construction, so the library can only ever hold the authorized AP.
- **Lockout-safe**: passive-listen first (a naturally re-joining client hands over the handshake
  for free); if it must nudge, it sends small, jittered, **client-targeted** deauth (never a
  broadcast flood), under a per-cycle hard cap, then goes passive. No WPS-PIN brute, no online
  guessing — nothing that can trip an AP lockout.
- Archives `<BSSID>/<timestamp>.{cap,22000}` and idles once every target has a fresh handshake.

### 2.2 The conveyor belt — `crackstack` pull (home-pie)
home-pie **pulls** the library from kali-pie over SSH (`rsync`) on a cron. The pull model is
deliberate: it works even after home-pie has been powered off, and a dropped link simply retries
next cycle rather than losing data. Trust is a dedicated, passphrase-free, **source-restricted**
key (`from="<home-pie IPs>"`) authorized on the capture box — least privilege, one direction.

### 2.3 `crackstack` — the Pi cracker (home-pie)
Cracks each pulled `.cap` with `markovgen`'s ordered candidates via **`aircrack-ng`**.
Design decisions, all learned the hard way (see §4):
- **aircrack-ng, not hashcat.** hashcat on a GPU-less Pi drives the CPU through `pocl` (OpenCL),
  which **segfaults during kernel init** on this ARM box (`EXIT=139`), and its stdin path crashes
  outright. `aircrack-ng` does CPU WPA cracking **natively, no kernel compilation** — the correct
  harness for a Pi. hashcat is reserved for the GPU fast-lane (the laptop).
- **`tried` is marked only AFTER a completed attempt.** An earlier version marked a handshake tried
  *before* cracking, so any crash/kill/reboot mid-crack silently burned it forever. Now a crashed
  run leaves it un-tried and it is retried next cycle.
- **`flock`** prevents overlapping cron runs; **`rsync` failure is non-fatal** (retry next cycle);
  the candidate budget is **env-overridable** (`CRACK_COUNT`) so production runs are bounded and a
  verification run can be small.

### 2.4 `markovgen` — the candidate model
An order-k character **Markov model** + **best-first (uniform-cost) search** that enumerates
candidates in descending probability order — generating *novel*, plausible passwords a static
wordlist can't contain, respecting WPA's 8-char minimum, seedable with target words. Standalone
repo: **github.com/Blitswolf/Markovgen-Model**.

### 2.5 `apresearch` — the exploit-intelligence model
When `searchsploit` finds no exact match for an AP, `apresearch` reasons over the *whole* local
exploit-db (TF-IDF + char-4-gram similarity) to find the nearest analogues, predict likely
vulnerability classes, and deep-mine those neighbours' exploit code into a concrete test plan.
Runs continuously at low priority to use spare CPU. Standalone repo:
**github.com/Blitswolf/Apresearch-Model**.

### 2.6 `apvulnd` — AP recon (kali-pie)
Low-priority timer that fingerprints the AP from harvested beacons (vendor/WPS/RSN/PMF/cipher),
runs `searchsploit`, feeds fingerprints to `apresearch`, and — only when the AP's management IP is
reachable — a bounded, **non-destructive** discovery sweep. Recon only; no brute, no lockout.

---

## 3. Data flow

```
client ⇄ AP  ──(4-way handshake, over the air)──▶  kali-pie monitor radio
                                                     │  wpacrack --harvest (scope-locked, gentle)
                                                     ▼
                              /opt/wpacrack/library/<BSSID>/<ts>.{cap,22000}
                                                     │  (rsync pull, home-pie initiates, retry-safe)
                                                     ▼
                              home-pie ~/crackstack/incoming/…
                                                     │  markovgen --model → ordered candidates
                                                     ▼
                                          aircrack-ng -w <candidates> <cap>
                                                     │  first hit
                                                     ▼
                                     ~/crackstack/cracked/<key>.key  (the PSK)

  (in parallel)  beacons → apvulnd fingerprint → apresearch → research plan per AP
```

---

## 4. What's proven vs. still limited (honest current state)

**Proven**
- Capture appliance runs headless, scope-locked, lockout-safe; library builds correctly.
- Conveyor belt works: home-pie's source-restricted pull key reaches kali-pie and rsyncs the
  library (verified end-to-end when the link is up).
- The aircrack harness is correct: a synthetically-generated WPA2 handshake for a known password
  cracks to that password with `aircrack-ng` (`mkhs.py` builds the test handshake; verified
  locally: `KEY FOUND! [ password ]`).
- `apresearch` builds its 47k-entry index and returns sensible vuln-class predictions.

**Limited / pending (the accurate caveats)**
- **home-pie's Wi-Fi link is unreliable** — it drops frequently, interrupting both management SSH
  and the belt's pull. The software tolerates this (pull retries next cycle), but a *live* single
  shot is flaky. **Fix is physical: put home-pie on Ethernet.**
- **`markovgen` is slow on a Pi with the large combined model** — loading the ~107 MB / 340k-context
  model and running best-first generation takes minutes on ARM. For a Pi cracker this means either a
  **smaller/lower-order model**, **pre-generated candidate lists**, or accepting it as a slow
  background grinder. aircrack itself is fine; candidate *generation* is the bottleneck.
- **hashcat is unusable on the Pi** (pocl CPU kernel-init segfault) — hence the aircrack harness;
  GPU cracking stays on the laptop.
- **A real handshake only lands when a client actually associates** to the lab AP; when no station
  is connected there is nothing to capture (you cannot deauth a client that isn't there).

---

## 5. Security & scope model
- Capture is allow-listed to the operator's own AP BSSIDs and refuses anything else.
- No online password guessing and no WPS-PIN brute anywhere — cracking is 100% offline, so no AP
  lockout can be tripped.
- Cross-host trust is one-directional, passphrase-free, and source-restricted, least-privilege.
- No secrets or site identifiers are committed (real configs and captures are git-ignored).

## 6. Related repos
- **WPAcrack.py** — the capture tool + harvest + this stack's components.
- **Markovgen-Model** — the candidate-generation model, standalone.
- **Apresearch-Model** — the exploit-intelligence model, standalone.
