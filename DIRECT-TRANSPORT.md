# Direct Yggdrasil peer transport outside an Android VPN

The complete installation procedure in this branch's [README](README.md) and [QUICKSTART](QUICKSTART.md) includes this patch. The commands below also describe applying it to an existing node.

For the rooted setup in this guide, a small patch to Yggdrasil v0.5.14 marks outgoing TCP peer sockets with Android's `protectedFromVpn` bit (`SO_MARK=0x20000`). Android chooses the physical network. Normal `Peers` are used; interface names are not pinned.

The existing runit service, ULA handler and firewall remain unchanged. This adds no network switching daemon or polling loop. Socket setup errors stop the connection. Other Termux/root processes keep their existing VPN path; no global routing or firewall bypass is installed.

The patch covers TCP and transports that use its dialer, including TLS. **QUIC is not covered.** Use TCP IPv4 literals for public peers, empty `InterfacePeers` and empty regular `Listen`. Wi-Fi multicast discovery is also enabled in the guide; its local peer connections use TLS/TCP. A hostname can still cause DNS resolution through the VPN. Preserve the existing private key and admin socket.

The bit layout comes from Android's [Fwmark.h](https://android.googlesource.com/platform/system/netd/+/refs/heads/main/include/Fwmark.h). This requires root socket privileges and was tested with Amnezia Premium IPv4-only on LineageOS 23 / Android 16, arm64. Check the actual socket path with your VPN.

## Build

Start in the root of this guide checkout. Use the v0.5.14 source checkout from the main guide, with no previous copy of this patch applied:

```sh
guide_patch="$PWD/patches/android-peer-vpn-bypass.patch"
cd ~/yggdrasil-go
git apply --check "$guide_patch"
git apply "$guide_patch"
PKGVER=0.5.14-direct.2 ./build -p -l "-checklinkname=0"
./yggdrasil -version
```

## Install on an existing node

Create a fresh backup directory before replacing the binary. Keep this backup private:

```sh
backup_dir=$(mktemp -d "$HOME/yggdrasil-before-direct.XXXXXX")
printf 'Backup: %s\n' "$backup_dir"
cp -p "$PREFIX/bin/yggdrasil" "$backup_dir/yggdrasil"
cp -p "$PREFIX/etc/yggdrasil.conf" "$backup_dir/yggdrasil.conf"
chmod 600 "$backup_dir/yggdrasil" "$backup_dir/yggdrasil.conf"
```

Edit the existing configuration. Do not generate a new identity. Use two or three current public TCP IPv4 peers in `Peers`, then set these fields:

```text
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

This enables built-in Wi-Fi discovery and advertisement using IPv6 link-local multicast. The regular `Listen: []` does not disable the listener created by multicast. The Wi-Fi regex does not bind public peers to Wi-Fi or add a network switching service. See [multicast details](README.md#wi-fi-multicast-discovery).

Install the patched daemon and start the same service:

```sh
sv -w 25 down yggdrasil
install -m 755 ~/yggdrasil-go/yggdrasil "$PREFIX/bin/yggdrasil"
sv -w 25 up yggdrasil
```

## Verify

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
su -c "$PREFIX/bin/ss -tnep"
```

The public peers should be up. Their TCP sockets should have `fwmark:0x20000` and a physical-network source address. Discovered LAN peers appear separately as link-local TLS connections on Wi-Fi. Check that other applications which require the VPN still use its address.

With the VPN enabled, switch Wi-Fi off and back on. Verify peer reconnection and the new physical source address **without restarting Yggdrasil**. Compare the daemon PID before and after. An existing connection may need time to reconnect; a route lookup alone does not prove handover.

On the tested phone, both transitions passed with the same daemon PID. The overlay HTTP endpoint remained reachable after each transition. Twenty-request ping measurements were:

| Network/test | Replies | Average RTT |
|---|---:|---:|
| Wi-Fi through VPN | 18/20 | 444 ms |
| Wi-Fi direct | 20/20 | 122 ms |
| After switching to mobile, first sample | 13/20 | 101 ms |
| Mobile, repeat sample | 20/20 | 90 ms |
| After returning to Wi-Fi | 20/20 | 144 ms |

These are small samples from one phone and network, not guaranteed latency or loss. The cause of the first mobile sample's losses was not established. A browsing interruption was reported after a network transition and cleared after the user reconnected the VPN; its cause was not established. The failed state was not captured.

Conversations calls were verified separately on Wi-Fi with Amnezia XRay and AmneziaWG active. About 66 seconds of bidirectional WebRTC media were captured with XRay and 42 seconds with AmneziaWG. In both tests media used `ygg0`; the Yggdrasil peer transport used only `wlan0`, outside the VPN. The user confirmed both calls worked, and Codex retained its VPN connection. The ULA was restored automatically when switching to AmneziaWG, without restarting Yggdrasil or adding configuration changes. These tests verify the media path outside Amnezia on the phone; they do not establish whether a relay was used inside Yggdrasil. Separate IPv4 candidate probes were observed through the VPN during the XRay test. Network switching during a call has not been tested with this patched build.

A clean reinstall from the published branch and a full Android reboot passed on 2026-10-09. An early Termux:Boot snapshot, about 25 seconds after boot, showed the service running with both peers connected through physical Wi-Fi and the three firewall rules restored. Post-reboot checks confirmed the original node identity, rule `1000`, table `200`, overlay HTTP 200 and automatic ULA restoration after the VPN connected. A bounded capture recorded peer TCP traffic only on `wlan0`, with none on the VPN interface. Other applications retained their VPN connection. The one-time diagnostic script removed itself; it is not part of the installation or a permanent helper.

The latency, handover, call, clean-install and reboot tests above used `MulticastInterfaces: []`. Wi-Fi multicast was enabled and checked separately on 2026-10-09: the same patched binary automatically established a direct local peer connection with the OpenWrt router, while both public peers stayed up. A 15-second capture showed discovery and peer traffic only on `wlan0`; node identity, firewall, rule `1000`, table `200` and VPN ULA were preserved, and Codex retained its VPN connection. This configuration change needs only a Yggdrasil restart; it adds no helper service. Those earlier tests were not repeated after enabling multicast.

## Restore

Set `backup_dir` to the saved backup path if using a new shell, then restore:

```sh
sv -w 25 down yggdrasil
install -m 755 "$backup_dir/yggdrasil" "$PREFIX/bin/yggdrasil"
install -m 600 "$backup_dir/yggdrasil.conf" "$PREFIX/etc/yggdrasil.conf"
sv -w 25 up yggdrasil
```

Keep the patch when rebuilding this version. An unpatched replacement binary does not provide this socket behavior; recheck the patch and socket path for newer versions.
