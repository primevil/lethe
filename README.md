# lethe

One command to get an **Always Free Oracle Cloud VM** ready for **Amnezia VPN (Xray)**.

> *Lethe* (Λήθη) is the river of forgetfulness in Greek mythology, and the root of the word *amnesia*.

## What it does

`lethe.sh` runs in OCI Cloud Shell and:

1. Creates (or reuses) a VCN, internet gateway, default route and public subnet.
2. Opens the required ports in the security list (SSH 22, Xray 443 TCP/UDP).
3. Finds an availability domain that offers the chosen shape.
4. Picks the newest Ubuntu image compatible with that shape.
5. Launches the instance, retrying automatically on *Out of host capacity*.
6. Configures the server on first boot via cloud-init:
   - adds a swap file (the micro VM has only 1 GB RAM),
   - installs `openssh-sftp-server` (required by the Amnezia client), Docker and `iptables-persistent`,
   - removes the OCI image's `REJECT` rule from the `FORWARD` chain and opens the ports in iptables.

It then waits until the server is ready and prints the public IP and SSH command.

## Requirements

- An Oracle Cloud account (the Always Free tier is enough).
- OCI Cloud Shell (the OCI CLI and `jq` are preinstalled and already authenticated).
- The [Amnezia VPN client](https://amnezia.org) on your computer.

## Quick start

1. Open Cloud Shell in the OCI console (the `>_` icon).
2. Upload `lethe.sh` (gear menu → **Upload**).
3. Run it, optionally adding your own SSH public key so you can connect from your computer:

```bash
EXTRA_PUBKEY='ssh-ed25519 AAAA... you@laptop' bash lethe.sh
```

or simply `bash lethe.sh`.

4. In the Amnezia client, add a server with the printed IP, user `ubuntu` and your SSH private key, then install the **Xray** protocol on port **443**.

## Settings

Every setting can be overridden with an environment variable, e.g. `SHAPE=VM.Standard.A1.Flex bash lethe.sh`.

| Variable | Default | Description |
|---|---|---|
| `SHAPE` | `VM.Standard.E2.1.Micro` | `VM.Standard.A1.Flex` for the (more powerful) ARM Always Free shape |
| `A1_OCPUS` / `A1_MEMORY_GB` | `2` / `12` | Only used with `A1.Flex` |
| `UBUNTU_VERSION` | `24.04` | Ubuntu release |
| `UBUNTU_MINIMAL` | `false` | Use the Minimal image |
| `TCP_PORTS` | `443` | Extra TCP ports to open (22 is always open) |
| `UDP_PORTS` | `443` | UDP ports to open |
| `SWAP_GB` | `2` | Swap file size (`0` disables swap) |
| `SSH_KEY` | `~/.ssh/oci_key` | Key pair in Cloud Shell, generated if missing |
| `EXTRA_PUBKEY` | *(empty)* | Your own public key, added to the server |
| `INSTANCE_NAME` | `ubuntu-free` | Instance display name |
| `LAUNCH_RETRIES` / `RETRY_DELAY` | `30` / `60` | Retries on *Out of host capacity* |
| `SSH_RETRIES` / `SSH_RETRY_DELAY` | `60` / `10` | How long to wait for SSH after launch |

Settings are validated before anything is created: ports must be numbers 1-65535, numeric settings non-negative integers and `EXTRA_PUBKEY` a single SSH public key line.

## Re-running

The script is safe to re-run. If the instance already exists, it only updates the network and port rules. To change open ports, re-run it with new `TCP_PORTS` / `UDP_PORTS`.

**Note:** the ingress rules of the subnet's security list are overwritten on every run. Any rule added manually in the console will be removed unless its port is in `TCP_PORTS` / `UDP_PORTS`.

## Troubleshooting

**Out of host capacity.** Free shapes are often sold out. The script retries automatically; if it gives up, try again later or raise `LAUNCH_RETRIES`.

**Amnezia error 1200 during installation.** Usually the server has no SFTP subsystem, so the client uploads empty files (check for an empty `Dockerfile` in `/opt/amnezia/*/`). The script installs `openssh-sftp-server`; on an existing server run `sudo apt install -y openssh-sftp-server`.

**Port check hangs (`nc -vz <ip> 443`).** Packets are dropped by the OCI security list. Re-run the script or check *Networking → VCN → Security Lists*.

**No internet with AmneziaDNS on macOS.** The client may send DNS queries to AmneziaDNS's private address (`172.29.172.254`) outside the tunnel. Set the DNS in the Amnezia client to `1.1.1.1` / `1.0.0.1`; queries still go through the encrypted tunnel.

**Server setup log.** `sudo tail -50 /var/log/vpn-bootstrap.log` on the server; the last line should be `BOOTSTRAP OK`.

## Security notes

- Never share `/opt/amnezia/xray/server.json`, Reality private keys or client IDs. If they leak, reinstall the Xray protocol in the Amnezia client to rotate them.
- Do not open port 53 publicly: AmneziaDNS works inside the tunnel, and a public resolver gets abused for DDoS amplification.
- Always Free instances that stay idle for 7 days may be reclaimed by Oracle; upgrading the account to Pay As You Go removes this while keeping the free limits.

## Development

The tests use [bats](https://github.com/bats-core/bats-core) with fake `oci`, `ssh` and `ssh-keygen` commands (`test/mocks`), so they need neither an Oracle Cloud account nor network access. CI runs them together with [ShellCheck](https://www.shellcheck.net) on every pull request and push to `main`.

```bash
bats test/
shellcheck -x lethe.sh test/mocks/* test/test_helper.bash
```

On macOS install `bats-core`, `shellcheck` and `gnu-sed` with Homebrew (the iptables rules are patched with GNU sed, as on the server).

## License

[BSD 3-Clause](LICENSE)
