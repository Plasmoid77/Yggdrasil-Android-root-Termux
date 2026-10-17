# Yggdrasil on rooted Android via Termux — Quick Setup

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

Follow these installation steps. The [full installation guide](docs/INSTALL.md) explains the setup and checks.

The ultimate profile sends TCP-based and QUIC/UDP peer traffic outside the Android VPN. It includes an event-driven ULA handler and a trusted-device inbound firewall. Android chooses Wi-Fi or mobile data. No extra switching service is needed. [Transport details and verification](DIRECT-TRANSPORT.md).

## 1. Requirements

- Rooted Android with working `su -c`.
- Termux and the separate **Termux:Boot Android app**.

Install both APKs from the same signing source: F-Droid or official GitHub releases. Mixed signatures prevent installation. [Termux installation requirements](https://github.com/termux/termux-app#installation).

### Install and activate Termux:Boot first

1. **Install Termux:Boot as an Android app** from the same signing source as Termux. You cannot install it with `pkg`.
2. **Open Termux:Boot once through its launcher icon** to enable startup at boot. Opening Termux does not activate Termux:Boot.

The steps below create one `10-services.sh` boot script and enable the service. `run` applies the firewall before each daemon start. Once setup is complete, you do not need to open Termux after every reboot. [Official Termux:Boot instructions](https://github.com/termux/termux-boot#how-to-use).

Android 12+ can kill the Termux supervisor while root Yggdrasil keeps running. When login or boot restores supervision, the service safely takes over the surviving session. Optional phantom-process settings affect all apps. With the default settings, a failed daemon cannot restart while its supervisor is absent. Read [background restrictions](docs/INSTALL.md#31-optional-android-child-process-restrictions).

The boot script holds a wake lock, which costs battery power. [Power policy](docs/INSTALL.md#124-wake-lock-and-battery-cost).

## Automatic installation

Install `git` if needed (`pkg install git`), then run these commands as the normal Termux user:

```sh
git clone --depth 1 --branch ultimate https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git ~/yggdrasil-android-guide
bash ~/yggdrasil-android-guide/install.sh
```

Run as the normal Termux user. Repeat `--peer URI` to set peers for a **new** configuration; replace the example URIs with current public peers:

```sh
bash ~/yggdrasil-android-guide/install.sh --peer tcp://192.0.2.10:12345 --peer quic://192.0.2.20:12345
```

These are documentation addresses, not working peers. Without `--peer`, a new node connects only to Wi-Fi multicast neighbours until you add public peers. Existing configurations and their peers are kept; `--peer` does not edit them. Use `--rebuild` to build again even when version `0.5.14-direct.3` is already installed. `--help` shows usage.

**Code is replaced; settings are created only when missing.** The installer backs up only files it replaces under `~/yggdrasil-backup-<time>/` (mode 700), mirroring `usr/`. It never copies `yggdrasil.conf` into this backup. Existing settings are kept; missing settings are created. No backup is made when nothing is replaced.

It is safe to run the installer again: unchanged files are left alone, changed code files are replaced with the service stopped first and started again, and settings are never overwritten. Each run reloads `YGG_IN`, resetting packet counters.

On a fresh install, keep a private copy of `yggdrasil.conf`: it contains the node's private key.

The installer was tested in a fake environment. It has **not yet run on a clean phone**. [Installer steps](docs/INSTALL.md#automatic-installation).

Continue below only for manual installation.

## 2. Install packages

```sh
pkg update
```

```sh
pkg install root-repo
```

```sh
pkg update
```

```sh
pkg install bash coreutils termux-tools git golang termux-services iproute2 procps nano curl openssh tcpdump
```

Run package and build commands as the normal Termux user. The packages provide:

- `bash`, `coreutils` and `termux-tools`: the shell, file utilities and wake lock.
- `git`/`golang`: tools to build the binaries.
- `termux-services`/`iproute2`/`procps`: supervision and networking tools.
- `nano`: the editor.
- `curl`, `openssh` and `tcpdump`: tools for the full guide's verification steps.

Root comes from `su`. You do not need `sudo` or `tsu`.

## 3. Build Yggdrasil

```sh
cd ~
git clone --depth 1 --branch ultimate https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git yggdrasil-android-guide
```

```sh
cd ~
```

```sh
git clone --depth 1 --branch v0.5.14 https://github.com/yggdrasil-network/yggdrasil-go.git
```

```sh
cd ~/yggdrasil-go
```

```sh
git apply --check ~/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch
git apply ~/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch
GOFLAGS=-p=2 PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"
```

Use fresh source and apply the patch once:

- `git apply --check` checks whether the patch fits.
- `git apply` changes the source.
- `./build` builds both binaries for installation below.

`PKGVER` labels the build. `-p` enables PIE. `-l` passes a linker option. The source changes mark TCP and QUIC/UDP sockets to bypass the VPN. [Command explanations and patch internals](docs/INSTALL.md#5-build-yggdrasil-natively-for-android).

## 4. Create the configuration

Generate a configuration for the new node:

```sh
./yggdrasil -genconf > ~/yggdrasil.conf
```

```sh
nano ~/yggdrasil.conf
```

Add **2–3 current nearby peers** using a supported transport from:

https://github.com/yggdrasil-network/public-peers

Example only: replace these documentation addresses with current peers:

```text
Peers: [
  tcp://192.0.2.10:12345
  tcp://192.0.2.20:12345
]
InterfacePeers: {}
Listen: []
MulticastInterfaces: [
  {
    Regex: "^wlan[0-9]+$"
    Beacon: true
    Listen: true
    Port: 0
    Priority: 0
  }
]
```

Use ordinary `Peers` without fixed interface names. IPv4 addresses avoid peer DNS lookups through the VPN. The patch covers all outgoing peer schemes in v0.5.14: TCP, TLS, WS, WSS, SOCKS, SOCKS+TLS and QUIC. UNIX sockets are local. For SOCKS, the marked socket connects to the proxy. The proxy controls the route from there. [Coverage](docs/INSTALL.md#104-direct-peer-transport).

Multicast advertises and discovers local Yggdrasil nodes on Wi-Fi (`wlanN`). It uses IPv6 link-local UDP port 9001, then creates TLS/TCP peer connections. `Port: 0` chooses the local TCP port automatically. Keep the regular `Listen: []`. A direct local peer connection lets a compatible OpenWrt status module show the phone's `node` address.

The Wi-Fi regex limits discovery only. Public peers still work over Wi-Fi or mobile data. No extra service or firewall rule is needed. To disable discovery, use `MulticastInterfaces: []`. [Details](docs/INSTALL.md#wi-fi-multicast-discovery).

Set:

```text
IfName: ygg0
```

If `AdminListen` is missing, add it as a top-level field inside the outer `{ ... }` configuration object:

```text
AdminListen: unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
```

## 5. Install binaries and configuration

```sh
install -m 755 ~/yggdrasil-go/yggdrasil "$PREFIX/bin/yggdrasil"
```

```sh
install -m 755 ~/yggdrasil-go/yggdrasilctl "$PREFIX/bin/yggdrasilctl"
```

```sh
install -m 600 ~/yggdrasil.conf "$PREFIX/etc/yggdrasil.conf"
```

## 6. Create the runit service

Copy the four service files from the guide clone made in step 3. First prepare the directory under a hidden name with `down` and `log/` inside, then rename it. runit ignores hidden directories, so it never sees a half-ready service:

```sh
mkdir -p "$PREFIX/var/service/.yggdrasil/log" "$PREFIX/var/run"
touch "$PREFIX/var/service/.yggdrasil/down"
mv "$PREFIX/var/service/.yggdrasil" "$PREFIX/var/service/yggdrasil"
install -m 700 ~/yggdrasil-android-guide/files/usr/var/service/yggdrasil/run "$PREFIX/var/service/yggdrasil/run"
install -m 700 ~/yggdrasil-android-guide/files/usr/var/service/yggdrasil/firewall "$PREFIX/var/service/yggdrasil/firewall"
install -m 700 ~/yggdrasil-android-guide/files/usr/var/service/yggdrasil/ula "$PREFIX/var/service/yggdrasil/ula"
install -m 700 ~/yggdrasil-android-guide/files/usr/var/service/yggdrasil/finish "$PREFIX/var/service/yggdrasil/finish"
```

`run` owns the root session, routing and Yggdrasil. It calls `firewall` before the daemon starts and starts `ula` after the node address appears. `finish` stops the recorded session even during startup, then removes leftover daemon/interface/rule state. [Full file contents and explanation](docs/INSTALL.md#9-create-the-runit-service).

### 6.1 IPv4-only VPN and physical Internet compatibility

The VPN helper is `fd43:<node low 112 bits>/128`. The primary physical helper is `fd42:<same bits>/128`. Both come from the key and must differ.

The handler uses only:

- UP real TUNs named `tunN`.
- The primary physical `rmnet_dataN`/`wlanN` selected with the socket mark.

Each interface must have global-scope IPv4 and no other global-scope IPv6. The handler preserves existing IPv6. It removes its own helper when the network gains global IPv6. Primary-uplink selection excludes IMS/hotspot interfaces; the handler does not detect their role.

After starting the service and connecting the VPN, identify the actual interfaces:

```sh
su -c 'ip -br addr'
su -c 'ip -4 route get 1.1.1.1 mark 0x20000'
su -c 'ip -6 -o addr show dev tun0 scope global'
```

The route lookup sends no packet. Replace `tun0` with the actual VPN name. Also inspect the physical `dev` returned by the lookup. The helper enables local compatibility, not general IPv6 Internet access. Yggdrasil destinations still use rule `1000` and `ygg0`.

The handler groups Netlink events into batches. It checks each named interface once and refreshes the primary uplink at most once per route/rule batch. It allows four additions per interface in ten seconds, including failures, to limit reset loops. There is no periodic timer.

The root session records its PID/start time. It waits up to ten seconds for the previous session to clean up before changing networking. Use runit. Do not launch simultaneous copies of `run`.

The `ula` helper removes this node's stale helpers at startup and completes address cleanup before exiting. Calls, Wi-Fi ↔ mobile handover and reboot have not yet been verified with these files. See [checks and limits](docs/INSTALL.md#evidence-and-limits).

### 6.2 Service logs

Copy the logger and create its settings only if missing:

```sh
mkdir -p "$PREFIX/var/log/sv/yggdrasil"
chmod 700 "$PREFIX/var/log/sv/yggdrasil"
install -m 700 ~/yggdrasil-android-guide/files/usr/var/service/yggdrasil/log/run "$PREFIX/var/service/yggdrasil/log/run"
if [ ! -e "$PREFIX/var/log/sv/yggdrasil/config" ]; then
    install -m 600 ~/yggdrasil-android-guide/files/usr/var/log/sv/yggdrasil/config "$PREFIX/var/log/sv/yggdrasil/config"
fi
```

The supplied `s262144`/`n4` settings rotate at 256 KiB and keep four old files plus `current`, about 1.25 MiB of normal log data. This is not a strict disk quota. [Full logger and settings](docs/INSTALL.md#93-service-logs).

Yggdrasil and ULA messages share the timestamped log:

```sh
tail -n 100 "$PREFIX/var/log/sv/yggdrasil/current"
tail -F "$PREFIX/var/log/sv/yggdrasil/current"
```

Stop following with Ctrl-C. Redact addresses before sharing logs. Check fresh timestamps and `sv status "$PREFIX/var/service/yggdrasil/log"`; an old log file does not prove the logger is running.

## 7. Configure the firewall

Create the trusted list only if it is missing, then edit it:

```sh
if [ ! -e "$PREFIX/etc/yggdrasil-trusted" ]; then
    install -m 600 ~/yggdrasil-android-guide/files/usr/etc/yggdrasil-trusted "$PREFIX/etc/yggdrasil-trusted"
fi
nano "$PREFIX/etc/yggdrasil-trusted"
```

The supplied template trusts nobody. Add one Yggdrasil address or prefix per line; an optional note follows it, and `#` starts a comment. An address without a prefix means /128. Use sources within `200::/7` only, with prefixes of /7 or longer. Example placeholder:

```text
200:1234:5678:9abc:def0:1234:5678:9abc trusted device
```

Apply the list as the normal Termux user; the script calls `su` itself:

```sh
"$PREFIX/var/service/yggdrasil/firewall"
```

No Yggdrasil restart is needed. `YGG_IN` accepts established/related replies, drops invalid packets, accepts trusted sources and drops the rest. Outbound traffic is not filtered. Malformed entries are reported as `Ignored line N` and skipped. Reload replaces the chain in one `ip6tables-restore --noflush` transaction; never flush Android's tables.

Inspect both chains after startup:

```sh
su -c '/system/bin/ip6tables -S INPUT'
su -c '/system/bin/ip6tables -L YGG_IN -n -v --line-numbers'
```

Expect one `-A INPUT -i ygg0 -j YGG_IN`. Check the full INPUT order. [Firewall tests](docs/INSTALL.md#15-verify-the-firewall) · [AFWall+ source-audit limits](docs/INSTALL.md#112-afwall) · [Allow a device: Syncthing example](docs/INSTALL.md#113-allow-a-device--example-syncthing).

## 8. Configure Termux:Boot

```sh
mkdir -p "$HOME/.termux/boot"
```

Create:

```sh
nano "$HOME/.termux/boot/10-services.sh"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh

termux-wake-lock
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
```

```sh
chmod +x "$HOME/.termux/boot/10-services.sh"
```

This is the only required boot script. It holds a Termux wake lock and starts runit. Opening Termux can also start the supervisor. `run` calls `firewall` on that path too. [Login and boot behavior](docs/INSTALL.md#123-manual-execution-and-shell-startup).

## 9. Start and enable Yggdrasil

Start the supervisor with the same wake-lock policy as boot:

```sh
"$HOME/.termux/boot/10-services.sh"
```

Wait for runit to find the service, then enable Yggdrasil:

```sh
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sv status yggdrasil >/dev/null 2>&1 && break
    sleep 1
done
if sv status yggdrasil >/dev/null 2>&1; then
    sv-enable yggdrasil && sv -w 45 up yggdrasil
else
    echo 'ERROR: runit did not create supervise/ok; check the service supervisor.' >&2
    false
fi
```

This waits at most fifteen seconds during installation. It enables the service only after `runit` has found it. It adds no background polling loop.

Manage Yggdrasil with:

```sh
sv status yggdrasil
```

```sh
sv up yggdrasil
```

```sh
sv down yggdrasil
```

```sh
sv restart yggdrasil
```

## 10. Yggdrasil control commands

Show this node:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getSelf"
```

Show peers:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
```

After editing the peer list in:

```text
$PREFIX/etc/yggdrasil.conf
```

restart Yggdrasil:

```sh
sv restart yggdrasil
```

## 11. Reboot

Termux:Boot runs `10-services.sh`. Runit starts Yggdrasil, and `run` applies the firewall first.

To prove boot startup, compare supervisor/daemon start times with the **first login shell**. Do this immediately after reboot, before manually starting services. Login can start runit, so finding a running service after opening Termux is not enough. Use the [read-only comparison command and checklist](docs/INSTALL.md#16-verify-everything-after-reboot).

Reboot has not yet been verified with these files. Trusted/untrusted firewall and bidirectional Syncthing checks do not prove boot startup. [Checks and limits](docs/INSTALL.md#evidence-and-limits).

## 12. Updating Yggdrasil

Follow [installation guide section 19](docs/INSTALL.md#19-updating-yggdrasil):

1. Select a release and build both Android/cgo binaries in a fresh directory.
2. Back up the old binaries and config.
3. Validate the existing config and node address.
4. Stop only Yggdrasil, install both binaries and restart it.

Keep the private key, peers, multicast, service/boot scripts and firewall. Do not regenerate the config. The section includes checks and rollback commands.

Keep the outgoing TCP-based and QUIC/UDP socket patch. It was tested on v0.5.14. Check and adapt it for a new release before building. A patch that applies cleanly or a version suffix does not prove VPN bypass. Verify physical peer sockets and traffic with the VPN active. An unpatched binary removes bypass.
