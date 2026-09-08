# Pipeline

A distributed, authorized-lab **WPA capture → crack → research** pipeline across a capture Pi, a
cracker Pi, and an optional GPU laptop. Each host does the workload it's suited to; small artifacts
(handshakes, fingerprints) move between them over SSH.

**Read [`DESIGN.md`](DESIGN.md) for the architecture, theory, and honest current-state notes.**

> ⚠️ Authorized use only — scoped to the operator's own AP (a BSSID allow-list). Defensive/research.

---

## Layout

```
DESIGN.md                     architecture + theory + proven/limited status
capture/                      the capture appliance (kali-pie)
  wpacrack.py                   wpacrack (single-shot + --harvest continuous library mode)
  wpacrack-harvest.service      systemd unit for continuous capture
  wpacrack.conf.example         site config (allow-listed targets, library, cooldown)
crack/                        the Pi cracker (home-pie)
  crackstack.sh                 pull kali-pie's library → markovgen → aircrack-ng, hardened
research/                     vuln research (kali-pie, relocatable to home-pie)
  apresearch.py                 exploit-intelligence model (TF-IDF over exploit-db)
  apresearch.service            continuous low-priority model service
  apvulnd.py                    AP fingerprint + searchsploit + non-destructive discovery
  apvuln.service / .timer       hourly recon
tools/
  mkhs.py                       generate a synthetic WPA2 handshake for a known password (testing)
```

`markovgen` (the candidate model) is its own repo — **github.com/Blitswolf/Markovgen-Model** — and
is deployed alongside `crackstack.sh` on the cracker.

## Function — how it runs

**Capture (kali-pie):** `sudo systemctl enable --now wpacrack-harvest` — sets monitor mode once,
continuously captures the allow-listed AP into `/opt/wpacrack/library/`, gently and scope-locked.

**Conveyor + crack (home-pie):** a `labs` user-cron runs `crackstack.sh` every 15 min → `rsync`
pulls the library from kali-pie (source-restricted key) → for each new `.cap`, `markovgen` emits
ordered candidates → `aircrack-ng` cracks → the PSK lands in `~/crackstack/cracked/`. First-hit-wins;
`tried` is marked only after a *completed* attempt; `flock` prevents overlap; `rsync` failures retry.

**Research (kali-pie):** `apvulnd` (hourly) fingerprints the AP and runs `searchsploit`; when it
finds nothing, `apresearch` reasons over the whole exploit-db to predict vuln classes and mine a
concrete test plan. `apresearch.service` keeps the model warm on spare CPU.

**GPU fast-lane (laptop):** for real firepower, pull a handshake and run
`hashcat -m 22000 -w4 -O <hash> <wordlist>` — orders of magnitude faster than a Pi.

## Testing the pipeline end-to-end

`tools/mkhs.py` builds a valid synthetic WPA2 4-way handshake for a chosen password (default
`password`, ESSID `PIPELINE-TEST`). Drop the resulting `.cap` into the library and the belt should
crack it back to the known password — a controlled end-to-end check that needs no real client.

## Status (see DESIGN.md §4)
Capture, conveyor, the aircrack harness, and apresearch are proven. Open items: home-pie's Wi-Fi is
unreliable (**move it to Ethernet**), and `markovgen` with the large model is slow on a Pi (use a
smaller model or pre-generated lists there). hashcat is Pi-incompatible (segfaults) — aircrack is the
Pi harness; hashcat stays on the GPU box.
