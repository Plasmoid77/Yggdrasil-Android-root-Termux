# Yggdrasil on rooted Android via Termux

Native Yggdrasil with a real `ygg0` interface, policy routing, runit supervision and a stateful IPv6 firewall. Root is required.

**[Quick setup](QUICKSTART.md) · [Full installation guide](docs/INSTALL.md)**

The **`ultimate` v3 profile** combines marked outgoing TCP-based/QUIC peer sockets outside the Android VPN with an event-driven WebRTC compatibility handler. It derives different local helpers from the node identity: `fd42:` on the primary IPv4-only physical uplink and `fd43:` on eligible IPv4-only VPN TUNs. Existing global-scope IPv6 is preserved. Android chooses the uplink; other applications retain their VPN policy. [Compatibility and verification matrix](docs/INSTALL.md#103-android-vpn--webrtcvoip-compatibility) · [Transport details](DIRECT-TRANSPORT.md).

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

## Before installation

1. Configure working root access through `su -c`.
2. Install **Termux and the separate Termux:Boot Android app** from matching signing sources.
3. **Open Termux:Boot once through its launcher icon** to activate its boot receiver.

The guides install one boot script, `10-services.sh`, and enable Yggdrasil. Termux:Boot is an Android app, not a `pkg` package. [Official usage instructions](https://github.com/termux/termux-boot#how-to-use).

## Service and autostart

```text
Termux:Boot → 10-services.sh → wake lock + runit
    → run: previous-session takeover → routing/firewall → Yggdrasil
        → batched VPN/physical ULA handler + bounded svlogd logs
    → finish: stop daemon and remove interface/rule
```

`run` applies the firewall before each daemon start, including login-triggered starts. No separate firewall boot script is needed. It records the root-session PID/start time and waits for a surviving predecessor's cleanup before touching networking. [Lifecycle](docs/INSTALL.md#94-previous-session-takeover) · [Firewall and AFWall+](docs/INSTALL.md#11-firewall).

Android 12+ child-process restrictions can kill the Termux supervisor while root Yggdrasil continues running. Supervision returns on the next Termux login or reboot; until then a failed daemon cannot be restarted. Disabling phantom-process monitoring is optional and affects all apps. The boot script's persistent wake lock also has a battery cost. [Background restrictions](docs/INSTALL.md#31-optional-android-child-process-restrictions) · [Power policy](docs/INSTALL.md#124-wake-lock-and-battery-cost).

v3 passed calls on IPv4-only mobile data with Amnezia and calls after mobile ↔ Wi-Fi transitions. Reboot was verified on v2 with the same boot/firewall logic; **v3 itself has not passed a reboot test**. Opening Termux can start runit, so prove boot autostart by comparing service start times with the first login. [Reboot verification](docs/INSTALL.md#16-verify-everything-after-reboot).

## Branches

Use installation instructions from the same branch as the chosen profile.

| Branch | Profile |
| --- | --- |
| [main](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/main) | Upstream Yggdrasil, routing, firewall and runit |
| [webrtc-vpn-compat](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/webrtc-vpn-compat) | Adds the event-driven VPN ULA handler |
| [direct-vpn-bypass](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/direct-vpn-bypass) | Adds marked outgoing TCP-based and QUIC peer sockets outside the VPN |
| [ultimate](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/ultimate) | v3: direct peers, distinct key-derived VPN/physical ULAs, root-session takeover, firewall in run, batched events and bounded logs |

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
