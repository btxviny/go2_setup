# Go2 EDU — WiFi-mode DDS Data Loss: Investigation Findings (Sept 2026)

## Symptom

`launch_all_sensors_docker.sh --wifi` gets clean DDS **discovery** (matched
publisher/subscriber counts on both domain 0 and domain 42, QoS matches) but
almost no actual **data**:

- `/camera/camera/color/camera_info` (tiny, single-UDP-packet message)
  publishes at 30 Hz in the container but only ~1.2 Hz was observed reaching
  the PC through the full `domain_bridge` + RViz2 pipeline.
- Large messages — raw depth, `/rslidar_points`, compressed color JPEG
  frames — were observed at effectively 100% loss.

The same `--ethernet` pipeline (identical bridge/QoS/topic config, just a
different physical link) has no such problem.

## Working theory going in (turned out to be wrong / incomplete)

The initial hypothesis was that CycloneDDS was still attempting **multicast**
for the actual data path even though discovery had already been patched to
use an explicit unicast `<Peer>` (see the existing WiFi-mode `<Peers>` /
`<ParticipantIndex>` scaffolding in `launch_all_sensors_docker.sh` and
`go2_sensors_docker/docker-compose.yml`'s `CONTAINER_CYCLONEDDS_URI`).
The plan was to add `<AllowMulticast>false</AllowMulticast>` to force
everything unicast.

**This was tested and is not the (whole) explanation:**

- Setting `AllowMulticast=false` on the **container's** domain-0 config broke
  something more fundamental: the RealSense and Hesai processes *inside the
  same container* also rely on that same multicast discovery to find each
  other (and even the container's own `ros2` CLI). With multicast globally
  disabled, discovery had no fallback (only the PC was listed as a unicast
  peer — not the container's own other local participants), and the
  container went from publishing ~17 topics down to **zero** — not even
  `/rosout`-adjacent topics from the sensor nodes. This is a real
  regression, not a fix. **Do not set `AllowMulticast=false` on the
  container side without also solving intra-container discovery.**
- Testing `AllowMulticast=false` on the **PC (subscriber) side only** wasn't
  needed to explain the small-message case, because of the next finding:

## Actual finding: small messages are fine end-to-end when isolated

With the container reverted to its known-working WiFi config (unicast
`<Peer>` only, multicast still enabled — the config `--wifi` mode has always
generated), a **direct** subscription on domain 0 (bypassing `domain_bridge`
and RViz2 entirely — plain `ros2 topic hz` from this PC straight to the
container) measured:

```
/camera/camera/color/camera_info: ~22-27 Hz sustained (expected 30 Hz)
```

That's close to the expected rate — nowhere near the ~1.2 Hz seen through
the full bridged pipeline. This means:

- The WiFi link itself, for small messages, is **not** the bottleneck.
- Discovery (multicast-based, unchanged) is **not** the bottleneck.
- Something in the `domain_bridge` → domain 42 → RViz2 chain is where the
  earlier ~1.2 Hz reading came from — or that earlier measurement was taken
  under different/worse WiFi conditions than this session's retest (both
  are plausible; not yet disambiguated — see Open Questions).

## Actual finding: large messages fail even in the simplest possible topology

Direct, no-bridge, explicit **best-effort** QoS subscriptions to
`/rslidar_points` and `/camera/camera/color/image_raw/compressed` both got
**zero** messages in 15s windows, tested straight against the container over
WiFi with nothing else in the path. This rules out, as the cause for large
messages specifically:

- `domain_bridge` (bypassed entirely in this test)
- QoS reliability/retry stalling (explicit best-effort subscriber used)
- Discovery/multicast (SPDP already confirmed matching in earlier sessions)

Follow-up link-level checks came back clean and don't explain it either:

- `ping -s 1400 -M do` (large, DF-set, ~1 CycloneDDS-fragment-sized ICMP
  payload) at up to 200 pps: **0% loss**, ~2-3ms RTT.
- MTU is 1500 on both `wlp2s0` (PC) and `wlan0` (dock): no obvious MTU
  mismatch/blackhole.

So large-message loss over this WiFi link is real, but not yet root-caused.
It's not simple raw packet loss (ping proves the link tolerates bursts of
1400B UDP-sized traffic fine) — something specific to how CycloneDDS frames
and paces large multi-fragment DDS samples over this link is being lost
before a single complete sample ever reassembles.

## Current state / what was left in place

- The container's WiFi CycloneDDS config (`cyclonedds_wifi_bridge.xml`,
  generated fresh by `launch_all_sensors_docker.sh --wifi` on every run) was
  restored to its original, known-working form: unicast `<Peer>` +
  `<ParticipantIndex>auto>`, multicast still enabled. **No script changes
  were made** — the `AllowMulticast=false` idea was tested live (via a
  manually-edited copy of the generated file on the dock) and reverted; it
  is not in `launch_all_sensors_docker.sh` and should not be added without
  also solving intra-container discovery first.
- AGENTS.md item 7 has been updated to point here instead of asserting the
  unconfirmed AP/client-isolation theory as settled fact.

## Open questions / next steps (not yet done)

1. **Disambiguate the small-message result**: re-run the *exact* full
   `--wifi` pipeline (domain_bridge + RViz2) right now and re-measure
   `camera_info`'s rate. If it's still ~1.2 Hz through the bridge but ~24 Hz
   direct, the bug is in `domain_bridge`'s domain-0→42 re-publish path
   specifically (worth testing bridging *only* `camera_info` alone, to rule
   out contention from the other 4+ topics domain_bridge is also mirroring
   simultaneously). If it's now also fast through the bridge, the original
   1.2 Hz reading was likely just a transient/worse-WiFi-moment measurement,
   not a structural bug.
2. **Root-cause the large-message loss**: try lowering CycloneDDS's
   `FragmentSize` (`<Internal><FragmentSize>`, default ~1344 bytes) to a
   smaller value to see if smaller fragments survive better on this WiFi
   hop; or capture with `tcpdump` on both ends during a failed
   `/rslidar_points` sample to see how many fragments actually arrive vs.
   are sent, rather than continuing to guess.
3. Only after (1) and (2) are understood should `launch_all_sensors_docker.sh`
   or the generated CycloneDDS configs actually be changed — no config edits
   are recommended from this session's findings alone.
