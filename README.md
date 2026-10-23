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
- Either OCI Cloud Shell (the OCI CLI and `jq` are preinstalled and already authenticated)
  or the OCI CLI and `jq` on your own computer (see [Running on your computer](#running-on-your-computer)).
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
5. Connect and check that your traffic leaves through the server. This should print the server's IP:

```bash
curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep ip=
```

## Running on your computer

Instead of Cloud Shell you can run the script on macOS or Linux (on Windows, use WSL). The SSH key then stays on your computer, ready for the Amnezia client.

1. Install the OCI CLI, `jq` and the OpenSSH client. If something is missing, `lethe.sh` stops and prints these commands for your system:

| System | Commands |
|---|---|
| macOS | `brew install oci-cli jq` |
| Debian, Ubuntu | `sudo apt-get update`<br>`sudo apt-get install -y jq openssh-client pipx`<br>`pipx install oci-cli`<br>`pipx ensurepath` |
| Fedora | `sudo dnf install -y jq openssh-clients pipx`<br>`pipx install oci-cli`<br>`pipx ensurepath` |
| Oracle Linux, RHEL, Rocky, Alma | `sudo dnf install -y jq openssh-clients python3-pip`<br>`python3 -m pip install --user oci-cli` |
| Arch | `sudo pacman -S --needed --noconfirm jq openssh python-pipx`<br>`pipx install oci-cli`<br>`pipx ensurepath` |

Other systems: see Oracle's [OCI CLI installation guide](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm). After `pipx ensurepath` (or `pip install --user`) open a new terminal so `~/.local/bin` is in your `PATH`.

2. Log in once. This opens the browser, creates an API key and writes `~/.oci/config`:

```bash
oci setup bootstrap
```

3. Run the script. It uses the tenancy from `~/.oci/config` (profile `DEFAULT`, or `OCI_CLI_PROFILE`) and checks that the OCI CLI can log in before creating anything:

```bash
bash lethe.sh
```

The SSH key is generated in `~/.ssh/oci_key` (change it with `SSH_KEY`); use that private key in the Amnezia client. `bash lethe.sh --help` lists all settings.

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
| `COMPARTMENT_ID` | `$OCI_TENANCY` in Cloud Shell, else the tenancy from `~/.oci/config` | Compartment for all resources |
| `OCI_CLI_PROFILE` | `DEFAULT` | Profile in `~/.oci/config` |

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

The tests use [bats](https://github.com/bats-core/bats-core) with fake `oci`, `ssh` and `ssh-keygen` commands (`test/mocks`), so they need neither an Oracle Cloud account nor network access. CI runs them together with [ShellCheck](https://www.shellcheck.net) on every pull request and push to `main`, and also in Debian, Ubuntu, Fedora, Oracle Linux, Rocky and Arch containers, where it runs the install commands from the table above and checks that `oci` works afterwards.

```bash
bats test/
shellcheck -x lethe.sh test/mocks/* test/test_helper.bash
```

On macOS install `bats-core`, `shellcheck` and `gnu-sed` with Homebrew (the iptables rules are patched with GNU sed, as on the server).

## License

[BSD 3-Clause](LICENSE)
