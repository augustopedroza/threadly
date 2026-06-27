# Threadly RCS Bridge — Fedora setup

Threadly reads SMS/MMS from the Android content provider, but **RCS chats can't be
read by any third-party app** (they live in Google Messages' private store, with no
API). On an RCS-default device most active threads are RCS, so they don't appear.

The workaround Beeper uses: pair to Google Messages' **"Messages for web"** companion
(QR code) via the open-source **mautrix-gmessages** bridge, which mirrors your threads
— **RCS included** — into a small **Matrix** homeserver. Threadly then reads those
rooms.

This guide runs the bridge on an always-on **Fedora** computer using **Podman**.

- **Read** path: bridge → Matrix → Threadly (new `GMessagesBridgeSource`).
- **Send** path: unchanged — the existing handoff opens Google Messages, which sends
  RCS natively. (Keeps scope small; no need to send through the bridge.)

> ⚠️ This impersonates the Google Messages web client. It's an **unofficial** protocol
> (fine for personal use on your own account/devices), it can break when Google changes
> things, and the bridge data holds your Google session — keep it local and backed up.

---

## 1. Prep the host

```bash
sudo dnf install -y podman podman-compose   # Podman is Fedora-native, rootless
loginctl enable-linger $USER                # containers run without you being logged in
```

**Keep it awake.** The host must stay online (the phone is the source of truth, like
Messages-for-web). If this is a desktop that sleeps:

- GNOME → Settings → Power → "Automatic Suspend: Off", **or** for a headless box:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

---

## 2. The two containers (Compose)

A lightweight Matrix homeserver (**conduwuit** — single binary, RocksDB) plus
**mautrix-gmessages**. Note the **`:Z`** on every volume — that's the SELinux label
Fedora requires so the containers can write their data (the #1 Fedora gotcha).

```yaml
# ~/rcs-bridge/compose.yml  (sketch — confirm exact keys against each project's docs)
services:
  homeserver:
    image: ghcr.io/girlbossceo/conduwuit:latest
    environment:
      CONDUWUIT_SERVER_NAME: "fedora.local"
      CONDUWUIT_ALLOW_REGISTRATION: "true"
    volumes: [ "./conduwuit:/var/lib/conduwuit:Z" ]
    ports: [ "6167:6167" ]
    restart: unless-stopped

  gmessages:
    image: dock.mau.dev/mautrix/gmessages:latest
    volumes: [ "./gmessages:/data:Z" ]
    depends_on: [ homeserver ]
    restart: unless-stopped
```

Start it:

```bash
mkdir -p ~/rcs-bridge && cd ~/rcs-bridge   # put compose.yml here
podman compose up -d                       # Podman 5 (Fedora 40+). Else: podman-compose up -d
```

---

## 3. Wire the bridge to the homeserver

1. Generate the bridge config:
   ```bash
   podman compose run --rm gmessages    # writes gmessages/config.yaml
   ```
2. Edit `gmessages/config.yaml`:
   - `homeserver.address: http://homeserver:6167`
   - `homeserver.domain: fedora.local`
   - under `permissions`, make your Matrix user an admin (e.g. `"@you:fedora.local": admin`).
3. Run once more to emit `gmessages/registration.yaml`, then point conduwuit at that
   registration file (conduwuit's appservice-registration step), and bring it up:
   ```bash
   podman compose up -d
   ```

---

## 4. Open the port to your LAN

Threadly runs on the Pixel and reaches the homeserver over your home network:

```bash
sudo firewall-cmd --permanent --add-port=6167/tcp
sudo firewall-cmd --reload
```

Keep it **LAN-only** — do **not** port-forward to the internet. For away-from-home
access later, use **Tailscale** rather than opening ports.

---

## 5. Pair to Google Messages (the RCS unlock)

1. Install **Element** (any Matrix client); register a user on `http://<fedora-ip>:6167`.
2. Start a chat with the bridge bot `@gmessagesbot:fedora.local` and send:
   ```
   login qr
   ```
3. It replies with a **QR code**. On the Pixel:
   **Google Messages → ⋮ → Device pairing → QR code scanner** → scan it.
4. Within a minute your threads backfill — **RCS included** — as Matrix rooms.

---

## 6. Verify (go/no-go) — do this BEFORE touching Threadly

In Element, confirm your **family RCS chats appear and update live**. That validates the
whole approach. If it's flaky here, it'll be flaky in Threadly — fix it at this layer
first. (You've spent an evening, not a month.)

---

## 7. Survive reboots (the Fedora-proper finish)

Once it works, convert to **Quadlet** systemd units so Podman launches the containers on
boot without a compose process babysitting them:

- Drop `.container` files in `~/.config/containers/systemd/`
- `systemctl --user daemon-reload`
- `systemctl --user start homeserver gmessages`

Optional but it's the clean Fedora way.

---

## 8. Threadly integration (the easy part)

- Add `GMessagesBridgeSource implements SmsSource` that talks to the homeserver via the
  Matrix client-server API (Dart [`matrix`](https://pub.dev/packages/matrix) package):
  sync rooms → map each room to a `MessageThread`. The organizing UI is untouched —
  this just swaps the read source.
- **Keep sending as the existing handoff** (opens Google Messages → native RCS send).

---

## Fedora-specific gotchas

- **SELinux:** if a container can't write its volume, you missed a `:Z` (or run
  `chcon -Rt container_file_t ./gmessages ./conduwuit`).
- **Rootless ports:** 6167 is fine rootless (>1024); binding <1024 needs extra config.
- **Lingering:** without `loginctl enable-linger`, rootless containers stop when you log
  out — step 1 covers it.
- **Pairing can expire** if the Pixel is offline too long — re-scan the QR to recover.
  Exempt Google Messages from battery optimization on the phone.
- **Back up `gmessages/`** — it holds your Google session (the sensitive bit).
- **It's unofficial** — `podman compose pull && podman compose up -d` periodically to
  track Google-side changes.

---

## References

- mautrix-gmessages docs: https://docs.mau.fi/bridges/go/gmessages/
- conduwuit: https://conduwuit.puppyirl.gay/ (or Conduit: https://conduit.rs/)
- Matrix Dart SDK: https://pub.dev/packages/matrix
- Tailscale: https://tailscale.com/
