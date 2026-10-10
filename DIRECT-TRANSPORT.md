# Direct Yggdrasil peer transport outside an Android VPN

The complete installation procedure in this branch's [full installation guide](docs/INSTALL.md) and [QUICKSTART](QUICKSTART.md) includes this patch. The commands below also describe applying it to an existing node.

For the rooted setup in this guide, a small patch to Yggdrasil v0.5.14 marks outgoing TCP-based and QUIC/UDP peer sockets with Android's `protectedFromVpn` bit (`SO_MARK=0x20000`). Android chooses the physical network. Normal `Peers` are used; interface names are not pinned.

The existing runit service, ULA handler and firewall remain unchanged. This adds no network switching daemon or polling loop. Socket setup errors stop the connection. Other Termux/root processes keep their existing VPN path; no global routing or firewall bypass is installed.

The patch covers every outgoing peer scheme supported by Yggdrasil v0.5.14:

| Peer scheme | Local socket / VPN handling |
| --- | --- |
| `tcp://` | Marked outgoing TCP socket |
| `tls://` | TLS over the same marked TCP dialer |
| `ws://` | WebSocket over the same marked TCP dialer |
| `wss://` | WebSocket/TLS over the same marked TCP dialer |
| `socks://` | Marked TCP connection to the SOCKS proxy |
| `sockstls://` | Marked TCP connection to the SOCKS proxy, then TLS |
| `quic://` | Marked UDP socket created before the QUIC handshake |
| `unix://` | Local IPC; no IP socket or VPN route |

Only the daemon's outgoing transport sockets get this handling. It does not mark application UDP, all root/Termux traffic or future transports added upstream. UDP calls addressed to Yggdrasil already enter `ygg0` through rule `1000`; the peer transport carries those packets whether the peer uses TCP or QUIC.

For QUIC, the daemon creates the UDP socket with the same Android socket control before passing it to quic-go. Socket-control failures abort the dial; failed handshakes and closed outgoing streams release the owned UDP socket. Non-Android QUIC dialing keeps upstream behavior.

Hostnames can still resolve through the VPN. SOCKS and environment HTTP proxies are intermediary services: the marked local connection does not control how the proxy itself reaches its destination. `unix://` is local and needs no bypass. The default guide keeps regular `Listen: []`; it does not expose public incoming listeners. Preserve the private key and admin socket.

The default example uses IPv4 TCP peers, empty `InterfacePeers` and empty regular `Listen`. Wi-Fi multicast discovers local TLS/TCP peers. You may select other supported transports in `Peers` without disabling the socket patch.

The bit layout comes from Android's [Fwmark.h](https://android.googlesource.com/platform/system/netd/+/refs/heads/main/include/Fwmark.h). This requires root socket privileges and was tested with Amnezia Premium IPv4-only on LineageOS 23 / Android 16, arm64. Check the actual socket path with your VPN.

## Build

Start in the root of this guide checkout. Use the v0.5.14 source checkout from the main guide, with no previous copy of this patch applied:

```sh
guide_patch="$PWD/patches/android-peer-vpn-bypass.patch"
cd ~/yggdrasil-go
git apply --check "$guide_patch"
git apply "$guide_patch"
PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"
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

Edit the existing configuration. Do not generate a new identity. Use two or three current nearby peers using any supported transport in `Peers`, then set these fields:

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

This enables built-in Wi-Fi discovery and advertisement using IPv6 link-local multicast. The regular `Listen: []` does not disable the listener created by multicast. The Wi-Fi regex does not bind public peers to Wi-Fi or add a network switching service. See [multicast details](docs/INSTALL.md#wi-fi-multicast-discovery).

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
su -c "$PREFIX/bin/ss -ulnep"
```

The public peers should be up. Outgoing TCP and QUIC UDP sockets should carry the `protectedFromVpn` bit (`0x20000`). TCP shows its physical source address directly; unconnected QUIC UDP sockets can show a wildcard address, so confirm the actual path by capturing packets to the chosen peer on `any` and checking the interface. Discovered LAN peers appear separately as link-local TLS connections on Wi-Fi. Check that other applications which require the VPN still use its address.

With the VPN enabled, switch Wi-Fi off and back on. Verify peer reconnection and the new physical source address **without restarting Yggdrasil**. Compare the daemon PID before and after. An existing connection may need time to reconnect; a route lookup alone does not prove handover.

The earlier `direct.2` build passed the following handover, latency, call, clean-install, reboot and multicast checks. They have not all been repeated on `direct.3`.

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

### All outgoing peer transports in direct.3

On 2026-10-09, the QUIC socket path was added to the same v0.5.14 patch. The runtime diff touches three source files: 56 added lines and 7 removed lines. It adds no permanent service, routing rule, firewall rule or timer. TCP socket setup is unchanged from `direct.2`.

Local Android/root fixtures passed real payload round trips and socket mark checks for TCP, TLS, WS, WSS, SOCKS and SOCKS+TLS. QUIC passed over IPv4 and IPv6, including owned UDP socket closure, repeated failed-dial cleanup and refusal to proceed without root socket-mark privileges. UNIX IPC and the existing core test suite also passed.

An isolated headless node then established a real public QUIC peer outside the active VPN. Its capture contained 85 packets on `wlan0`, including replies, and none on `tun0`; its UDP sockets carried `0x20000`. Some other public candidates timed out or refused connections: public-list membership does not guarantee availability.

The installed `direct.3` daemon was subsequently checked with both existing TCP peers and a temporary pinned public QUIC peer. That peer was removed after the initial verification; the persistent peer configuration stayed unchanged. Native identity, multicast, the configuration and service/boot file hashes, full firewall rules, ULA, routing, overlay HTTP and Codex's VPN connection were preserved. No test daemon or collector was retained. The additional QUIC-only checks below used separate temporary configurations.

### QUIC handover, calls and reboot

On 2026-10-09, a QUIC-only configuration with TCP peers and multicast disabled passed Wi-Fi → mobile → Wi-Fi checks without restarting Yggdrasil. Captures showed public-peer UDP on the physical interfaces and none on the VPN interface. The node identity, routing, three Yggdrasil firewall rules and VPN access were preserved. Short ping samples had packet loss and variable RTT; these results do not establish lossless handover or latency equivalence to TCP.

Calls with VLESS/Xray, including Monocles/Conversations interoperability, were reported successful by the user. A further Wi-Fi call lasting more than an hour with VLESS/Xray was reported successful on 2026-10-10. The bounded captures did not record the media of those calls, so these are user-reported call results. With AmneziaWG and two Russian QUIC peers, fresh connections to the actual XMPP server succeeded on mobile data and the application reported connected; a QUIC-only call with that VPN protocol was not separately confirmed.

Some public peers timed out, and earlier attempts lost overlay reachability. The reference web endpoint and ICMP probes also failed in a normal TCP baseline while the XMPP server remained reachable. Their cause was not established. Check the actual application endpoint as well as peer status; a public-list entry or an `up` peer alone does not prove application readiness.

On 2026-10-10, a full Android reboot passed with `direct.3`, two QUIC peers and TCP/multicast disabled. A one-time Termux:Boot observer recorded the service, both marked UDP sockets and both completed peer handshakes about 28 seconds after boot. A second snapshot showed table `200` and automatic ULA restoration after the VPN appeared. The early capture recorded 122 peer UDP packets on `wlan0`, none on the VPN interface, with no kernel capture drops. The observer only read state and removed its boot entry after completion.

Post-reboot checks preserved the node address/key and hashes of both binaries, the config and service/boot scripts. They confirmed the three firewall rules, routing, ULA, a fresh XMPP connection, HTTP 200, 20/20 ICMP replies (126.654 ms mean RTT), physical QUIC traffic and continued VPN access for Codex. No manual service start or repair preceded these checks. After verification, the original TCP peer configuration with Wi-Fi multicast was restored; QUIC support remains in the binary.

## Updating to another upstream release

Follow [installation guide section 19](docs/INSTALL.md#19-updating-yggdrasil) for the complete update and rollback procedure. Build in a fresh directory, preserve the installed configuration/key and replace both binaries only after validation. This patch is tested on v0.5.14: review and check it against the selected new release before applying it. If it no longer applies, port and review it or keep the working release; do not install an unpatched build as an equivalent replacement. Textual patch success and a local version suffix do not prove the new binary bypasses the VPN. Verify the actual public peer socket marks and physical traffic, local multicast, network reconnection and a call with the VPN active before discarding the backup.

## Restore

Set `backup_dir` to the saved backup path if using a new shell, then restore:

```sh
sv -w 25 down yggdrasil
install -m 755 "$backup_dir/yggdrasil" "$PREFIX/bin/yggdrasil"
install -m 600 "$backup_dir/yggdrasil.conf" "$PREFIX/etc/yggdrasil.conf"
sv -w 25 up yggdrasil
```

Keep the patch when rebuilding this version. An unpatched replacement binary does not provide this socket behavior; recheck the patch and socket path for newer versions.
