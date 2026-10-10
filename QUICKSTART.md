# Yggdrasil on rooted Android via Termux — Quick Setup

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

Installation steps. See the [full installation guide](docs/INSTALL.md) for explanations and verification.

## 1. Requirements

- Rooted Android with working `su -c`.
- Termux and the separate **Termux:Boot Android app**.

Install Termux and Termux:Boot from the same signing source: F-Droid with F-Droid, or official GitHub builds with matching signatures. See [Termux installation requirements](https://github.com/termux/termux-app#installation).

### Install and activate Termux:Boot first

1. **Install Termux:Boot as an Android app**, using matching signatures with Termux. It is not installed by `pkg`.
2. **Open Termux:Boot once through its launcher icon** to enable automatic execution at boot. Opening Termux does not replace this step.

The steps below create both boot scripts and enable the service. After completing them, you do not need to open Termux after every reboot. [Official Termux:Boot instructions](https://github.com/termux/termux-boot#how-to-use).

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
pkg install git golang termux-services iproute2 procps nano curl openssh tcpdump
```

## 3. Build Yggdrasil

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
./build -p -l "-checklinkname=0"
```

## 4. Create the configuration

```sh
./yggdrasil -genconf > ~/yggdrasil.conf
```

```sh
nano ~/yggdrasil.conf
```

Add **2–3 current public peers** from:

https://github.com/yggdrasil-network/public-peers

Example:

```text
Peers: [
  tcp://peer1.example:12345
  tls://peer2.example:23456
]
```

Enable built-in Wi-Fi multicast discovery in the existing configuration object:

```text
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

This advertises and discovers local nodes on `wlanN` using IPv6 link-local UDP port 9001, then establishes TLS/TCP peer connections. `Port: 0` chooses the local TCP port automatically; multicast works even with an empty regular `Listen` field. Keep public peers for connectivity without a local peer. A direct connection to a compatible OpenWrt router lets its status module show the phone's `node` address. No extra helper service or `ygg0` firewall rule is needed. Set `MulticastInterfaces: []` to disable discovery. [Details](docs/INSTALL.md#wi-fi-multicast-discovery).

Set:

```text
IfName: ygg0
```

Add `AdminListen` as a top-level field inside the outer `{ ... }` configuration object if it is not already present:

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

```sh
mkdir -p "$PREFIX/var/service/yggdrasil"
```

```sh
touch "$PREFIX/var/service/yggdrasil/down"
```

Create `run`:

```sh
nano "$PREFIX/var/service/yggdrasil/run"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh

# Send all traffic destined for the Yggdrasil 200::/7 network to routing table 200.
su -c 'ip -6 ru add to 200::/7 lookup 200 prio 1000' 2>/dev/null || true

# Remove a stale ygg0 interface left by an unclean previous shutdown.
su -c 'ip link del ygg0' 2>/dev/null || true

# Prepare the standard /dev/net/tun path for the TUN interface.
su -c 'mkdir -p /dev/net && ln -sf /dev/tun /dev/net/tun'

# Merge stderr into stdout for runit service output.
exec 2>&1

# Start Yggdrasil with root privileges.
su -c "/data/data/com.termux/files/usr/bin/yggdrasil -useconffile /data/data/com.termux/files/usr/etc/yggdrasil.conf" &
YGG_PID=$!

# Wait up to 30 seconds for ygg0 to appear.
for i in $(seq 1 30); do
    su -c 'ip link show ygg0' >/dev/null 2>&1 && break || true
    sleep 1
done

# Once ygg0 exists, route the Yggdrasil network through it in table 200.
if su -c 'ip link show ygg0' >/dev/null 2>&1; then
    su -c 'ip r add 200::/7 dev ygg0 metric 128 table 200'
else
    echo "ERROR: ygg0 did not appear" >&2
    su -c "kill $YGG_PID" 2>/dev/null
    exit 1
fi

# Keep the run script alive for as long as the Yggdrasil process is running.
wait "$YGG_PID"
```

Create `finish`:

```sh
nano "$PREFIX/var/service/yggdrasil/finish"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh

# Stop Yggdrasil.
su -c "pkill -f '[y]ggdrasil -useconffile /data/data/com.termux/files/usr/etc/yggdrasil.conf' 2>/dev/null || true"

# Remove ygg0 if it still exists.
su -c 'ip link del ygg0 2>/dev/null || true'

# Remove the policy rule that sends the Yggdrasil network to routing table 200.
su -c 'ip -6 ru del to 200::/7 lookup 200 prio 1000 2>/dev/null || true'

exit 0
```

Make both scripts executable:

```sh
chmod +x "$PREFIX/var/service/yggdrasil/run" "$PREFIX/var/service/yggdrasil/finish"
```

## 7. Configure the firewall

```sh
mkdir -p "$HOME/.termux/boot"
```

Create:

```sh
nano "$HOME/.termux/boot/05-ygg-firewall.sh"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh

# Allow replies to connections initiated by the phone and related traffic.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'

# Drop packets that conntrack cannot classify as a valid connection state.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP'

# Drop all other inbound traffic arriving through the Yggdrasil interface.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -j DROP 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -j DROP'
```

```sh
chmod +x "$HOME/.termux/boot/05-ygg-firewall.sh"
```

Apply it immediately:

```sh
"$HOME/.termux/boot/05-ygg-firewall.sh"
```

## 8. Configure Termux:Boot

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

The firewall script can also be executed manually from Termux to apply its rules to the current boot; see the [manual command and checks](docs/INSTALL.md#11-firewall). Opening Termux or starting the supervisor does not run that script; Termux:Boot supplies the automatic boot trigger. [Details](docs/INSTALL.md#123-manual-execution-and-shell-startup).

## 9. Start and enable Yggdrasil

Start `termux-services` in the current Android session:

```sh
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
```

Enable Yggdrasil:

```sh
sv-enable yggdrasil
```

Yggdrasil is now managed with:

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
sudo "$PREFIX/bin/yggdrasilctl" -endpoint="unix://$PREFIX/tmp/yggdrasil.sock" getSelf
```

Show peers:

```sh
sudo "$PREFIX/bin/yggdrasilctl" -endpoint="unix://$PREFIX/tmp/yggdrasil.sock" getPeers
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

Reboot Android normally.

Termux:Boot will restore the firewall and start `termux-services`; `runit` will then start Yggdrasil automatically.

## 12. Updating Yggdrasil

Follow [installation guide section 19](docs/INSTALL.md#19-updating-yggdrasil): select a release, build both Android/cgo binaries in a fresh directory, back up the old binaries and config, validate the existing config and node address, then stop only Yggdrasil, install both binaries and restart it. Keep the private key, peers, multicast, service/boot scripts and firewall; do not regenerate the config. The section includes post-update checks and rollback commands.

Use this branch's installed profile. A direct build needs the patch and checks from the [direct-vpn-bypass branch](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/blob/direct-vpn-bypass/docs/INSTALL.md#19-updating-yggdrasil), rather than an unpatched upstream replacement.
