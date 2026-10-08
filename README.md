# clipsync

Sync the clipboard between a Linux/X11 desktop and an Android phone over Tailscale.

- Desktop copy → phone clipboard: automatic
- Phone copy → desktop clipboard: tap a widget button

## Requirements

Desktop: Linux with X11, Zig 0.16, Tailscale

```sh
sudo apt install xclip libx11-dev libxfixes-dev
```

Phone: Android with the Tailscale app (with MagicDNS on, or know the desktop's tailscale IP), plus Termux, Termux:API, Termux:Widget and Termux:Boot (all from F-Droid). In Termux:

```sh
pkg install termux-api zig
```

If Termux's packaged `zig` is older than 0.16, install Zig 0.16 manually (e.g. download a release tarball into `$PREFIX`).

## Install

### Desktop

```sh
zig build-exe desktop.zig -lc -lX11 -lXfixes -O ReleaseSafe
mkdir -p ~/.local/bin
cp desktop ~/.local/bin/clipsync
```

### Phone (build inside Termux)

```sh
zig build-exe phone.zig -lc -O ReleaseSmall
mkdir -p ~/bin
cp phone ~/bin/clipsync-phone
```

## Run

The desktop takes two arguments: its own tailscale IP and the phone's tailscale IP (the phone IP is used as an access-control allowlist — only that peer may connect). The phone connects to the desktop by its MagicDNS name (or IP).

Find your tailscale IPs with `tailscale ip -4`. The examples below use placeholder addresses — replace them with yours.

### Desktop

```sh
~/.local/bin/clipsync 100.120.51.67 100.110.149.26
```

To start it automatically, create `~/.config/systemd/user/clipsync.service`:

```ini
[Unit]
Description=Clipboard sync over Tailscale
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=%h/.local/bin/clipsync 100.120.51.67 100.110.149.26
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now clipsync
```

### Phone: receive from desktop

```sh
termux-wake-lock
~/bin/clipsync-phone sub mypc.your-tailnet.ts.net 7777
```

To start at boot, open the Termux:Boot app once, then:

```sh
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/clipsync <<'EOS'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
while true; do
    ~/bin/clipsync-phone sub mypc.your-tailnet.ts.net 7777
    sleep 5
done
EOS
chmod +x ~/.termux/boot/clipsync
```

### Phone: send to desktop

```sh
mkdir -p ~/.shortcuts
cat > ~/.shortcuts/push-clip <<'EOS'
#!/data/data/com.termux/files/usr/bin/sh
~/bin/clipsync-phone push mypc.your-tailnet.ts.net 7777
EOS
chmod +x ~/.shortcuts/push-clip
```

Add the Termux:Widget widget to your home screen and tap `push-clip`.

## Troubleshooting

- Phone can't connect: verify the phone's tailscale IP matches the second argument you passed to the desktop, and allow the port: `sudo ufw allow in on tailscale0 to any port 7777 proto tcp`
- Phone can't resolve the name: rebuild in Termux with `-lc`, and enable "Use Tailscale DNS settings" in the Tailscale app
- Stops working after a while: set Termux battery usage to Unrestricted in Android settings

## Security

The desktop binds to the first argument (our tailscale IP) and only accepts connections from the second argument (the phone's tailscale IP). For defense in depth, also restrict access with Tailscale ACLs.
