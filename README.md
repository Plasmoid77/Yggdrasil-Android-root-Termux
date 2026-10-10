# Yggdrasil on rooted Android via Termux

Native Yggdrasil node with a real `ygg0` interface, policy routing, runit supervision and a stateful IPv6 firewall. Root is required.

**[Quick setup](QUICKSTART.md) · [Full installation guide](docs/INSTALL.md)**

You are viewing the **`main`** branch. This branch uses upstream Yggdrasil. Android's existing routing and VPN policy determine public-peer transport.

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

## Before installation

1. Configure working root access through `su -c`.
2. Install **Termux and the separate Termux:Boot Android app** from matching signing sources.
3. **Open Termux:Boot once through its launcher icon.** This enables its boot receiver; opening the Termux terminal is a different action.

Then follow the [quick setup](QUICKSTART.md) or the [full guide](docs/INSTALL.md). They create both boot scripts and enable the Yggdrasil service. Termux:Boot is an Android app, not a package installed with `pkg`. [Official usage instructions](https://github.com/termux/termux-boot#how-to-use).

## Architecture

The final setup looks like this:

```text
Android boot
│
└── Termux:Boot
    │
    ├── 05-ygg-firewall.sh
    │   └── restores the IPv6 INPUT policy for ygg0
    │
    └── 10-services.sh
        ├── termux-wake-lock
        └── starts termux-services / runit
            │
            └── yggdrasil
                │
                ├── run
                │   ├── adds RPDB rule 1000
                │   ├── removes stale ygg0
                │   ├── prepares /dev/net/tun
                │   ├── starts Yggdrasil as root
                │   ├── waits for ygg0
                │   ├── adds 200::/7 to table 200
                │   └── waits for Yggdrasil
                │
                └── finish
                    ├── stops Yggdrasil
                    ├── removes ygg0
                    └── removes RPDB rule 1000
```

The important separation is:

```text
Termux:Boot = one-shot boot initialization
runit       = long-running service supervision
```

Termux:Boot does not replace `runit`. It only starts the supervisor after Android boots.

## Autostart and the firewall

After installation, Termux:Boot runs `05-ygg-firewall.sh` and then `10-services.sh` from `~/.termux/boot/`. The first applies the firewall; the second starts the runit supervisor. With the app activated, both scripts installed and the service enabled, opening Termux after every reboot is unnecessary.

The firewall script is an ordinary shell script and can also be run manually from Termux; its commands request root through `su`:

```sh
"$HOME/.termux/boot/05-ygg-firewall.sh"
```

Opening a Termux login shell can start the service supervisor through `start-services.sh`, but it does not execute the files in `~/.termux/boot/` or apply this firewall. If Termux:Boot is omitted, another boot trigger must explicitly run the scripts; running them manually only applies them to the current boot. [Autostart details](docs/INSTALL.md#12-autostart-with-termuxboot) · [Firewall setup and checks](docs/INSTALL.md#11-firewall).

## Branches

Use the installation guide and QUICKSTART from the same branch.

| Branch | Profile |
| --- | --- |
| [main](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/main) | Upstream Yggdrasil, routing, firewall and runit |
| [webrtc-vpn-compat](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/webrtc-vpn-compat) | Adds the event-driven VPN ULA handler |
| [direct-vpn-bypass](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/direct-vpn-bypass) | Adds marked outgoing TCP-based and QUIC peer sockets outside the VPN |

The [full guide](docs/INSTALL.md) contains prerequisites, installation, Wi-Fi multicast, verification, service management, updates and removal.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
