# Yggdrasil on rooted Android via Termux — Quick Setup

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

Minimal installation procedure without explanations or verification steps.

## 1. Requirements

- Rooted Android with working `su -c`.
- `Termux` and `Termux:Boot`; launch `Termux:Boot` at least once from the Android launcher.

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

### 6.1 Optional: WebRTC calls while an Android VPN is active

If Yggdrasil works through an Android VPN but a WebRTC app such as Conversations cannot establish calls while it remains inside the VPN, check the VPN interface:

```sh
su -c 'ip -br addr'
```

On the tested AmneziaVPN setup the VPN interface was `tun0`. If it has only link-local IPv6 (`fe80::`) and no usable global/ULA IPv6 address, add the tested synthetic ULA:

```sh
su -c 'ip -6 addr replace fd42:7967:6772::1/128 dev tun0'
```

Verify:

```sh
su -c 'ip -br -6 addr show dev tun0'
```

For Conversations, restart the app before testing:

```sh
su -c 'am force-stop eu.siacs.conversations'
```

The synthetic address only gives WebRTC a usable IPv6 base socket. Yggdrasil destinations still match:

```text
1000: from all to 200::/7 lookup 200
```

and therefore leave through `ygg0`; non-Yggdrasil traffic remains under the normal Android/VPN policy.

Remove the workaround with:

```sh
su -c 'ip -6 addr del fd42:7967:6772::1/128 dev tun0'
```

If the VPN already has usable non-link-local IPv6, this workaround is normally unnecessary. See the full README for the explanation and verification procedure.

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
