# Easy-openvas

Setup a full OpenVAS service easily with Docker.

## Prerequisites

- A user account with sudo privileges.
- Recommended CPU: 2 vCPU minimum, 4 vCPU for a comfortable experience.
- Recommended RAM: 8 GB minimum, 12 GB or more for a comfortable experience.
- Recommended disk space: at least 100 GB free.
- A stable internet connection for Docker image downloads and vulnerability feed synchronization.
- Network access to the targets you want to scan.

Easy-OpenVAS can be deployed in two ways:

1. Fresh Debian 13 server
   Easy-OpenVAS installs Docker automatically. This mode currently targets Debian 13 (Trixie).
2. Existing Docker server
   Easy-OpenVAS reuses the existing Docker installation.

Easy-OpenVAS never automatically removes existing container runtimes or container-management software. If conflicting packages prevent Docker CE installation in Fresh Debian mode, the installer stops and asks the administrator to resolve the conflict manually.

For an existing Docker server, the prerequisites are:

- Docker daemon operational.
- Docker Compose v2 available through `docker compose`.
- Active Docker endpoint must be local, not a remote `tcp://` or `ssh://` context.
- No existing Easy-OpenVAS installation in `/opt/openvas`.
- No existing Greenbone/OpenVAS Docker Compose project detected.
- TCP ports `443` and `9392` available.
- Basic CPU, RAM, and disk capacity checks pass.

When using an existing Docker server, Easy-OpenVAS reuses Docker as-is. It does not install, uninstall, upgrade, reconfigure, restart or otherwise manage the Docker daemon, and it does not stop or modify existing containers, volumes, networks or workloads. The installer checks for port conflicts, Greenbone project collisions, local Docker context, and available resources before asking for explicit deployment confirmation.

## Official documentation

The official OpenVAS / Greenbone Community Containers documentation is available here:

<https://greenbone.github.io/docs/latest/22.4/container/index.html>

## Installation

On the Debian 13 machine, either clone this repository:

```bash
git clone https://github.com/LCIT-CyberSecurity/Easy-openvas.git
cd Easy-openvas
```

It is also possible to copy only the content of `Openvas-installer.sh` into a new script file on the Debian 13 machine.

```bash
nano Openvas-installer.sh
```

Make the script executable:

```bash
chmod +x Openvas-installer.sh
```

Run the installer with sudo:

```bash
sudo ./Openvas-installer.sh
```

The installer displays a menu:

```text
1. Install OpenVAS on a fresh Debian 13 server
2. Install OpenVAS on an existing Docker server
3. Exit
```

Option 1 checks that the system is Debian 13 and that Docker is not already installed before installing Docker. Option 2 checks the existing Docker environment and then deploys only the Easy-OpenVAS Greenbone/OpenVAS stack.

## Updating Docker images without losing data

**Before any update, make a complete backup or snapshot of the Debian machine.** This is strongly recommended so you can restore the full OpenVAS installation if the update fails.

OpenVAS data such as users, scan tasks, reports, configuration, PostgreSQL data, and feeds are stored in Docker volumes. A normal image update recreates containers but keeps these volumes.

To update the Docker images safely:

```bash
sudo docker compose -f /opt/openvas/compose.yaml pull
sudo docker compose -f /opt/openvas/compose.yaml up -d
```

Then check the container status:

```bash
sudo docker compose -f /opt/openvas/compose.yaml ps
```

Do not use the following commands unless you intentionally want to delete OpenVAS data:

```bash
sudo docker compose -f /opt/openvas/compose.yaml down -v
sudo docker volume prune
sudo docker system prune --volumes
```

The `-v` and `--volumes` options remove Docker volumes. Removing volumes can delete OpenVAS configuration, scan tasks, reports, and database content.

## OpenVAS service FQDN

Easy-OpenVAS distinguishes the Debian/Docker host name from the OpenVAS service FQDN used by administrators and users.

Example:

```text
Docker / Linux host: docker01.example.com
OpenVAS service:    openvas.example.com
```

During installation, the script detects the host FQDN and, when it contains a usable domain, proposes `openvas.<domain>`:

```text
docker01.example.com
-> proposed OpenVAS FQDN: openvas.example.com
```

The installer then asks:

```text
OpenVAS FQDN [openvas.example.com]:
>
```

Press Enter to accept the proposed value, or enter the full FQDN you want to use, for example:

```text
openvas.example.com
scan.example.com
scan.security.example.com
host.domain.example
```

The `openvas.` prefix is only a default proposal. It is not mandatory.

The chosen FQDN should normally have a DNS entry that lets users reach the OpenVAS service. The installer performs an informational DNS check:

```text
[OK] DNS name openvas.example.com resolves to 192.168.1.25
```

If the DNS entry does not exist yet, installation continues:

```text
[WARNING] DNS name openvas.example.com does not currently resolve.
[WARNING] Create or verify the DNS entry before accessing OpenVAS with this name.
```

The DNS entry can be created before or after installation.

## Web interface URL

After installation, the OpenVAS web interface is available at:

```text
https://<openvas-fqdn>
```

Examples:

```text
https://openvas.example.com
https://scan.security.example.com
```

The installer configures Greenbone nginx for the OpenVAS FQDN selected during installation. The server IP address is useful for diagnostics, but the recommended access URL is the OpenVAS FQDN.

## Port

No port needs to be added to the URL with the default OpenVAS Docker Compose configuration.

HTTPS uses the standard port `443`, so this is enough:

```text
https://<openvas-fqdn>
```

Only specify a port if you changed the Docker Compose port mapping manually. In the default OpenVAS Compose file, port `9392` redirects to `443`.

## Network access restriction

By default, this installer makes the OpenVAS web interface reachable from any IP address assigned to the Debian server. Access is not restricted to `127.0.0.1`.

If you want to restrict access, edit `/opt/openvas/compose.yaml` and bind the web ports to a specific address.

To allow access only from the Debian server itself:

```yaml
ports:
  - 127.0.0.1:443:443
  - 127.0.0.1:9392:9392
```

To allow access only through one specific server IP:

```yaml
ports:
  - 192.168.1.42:443:443
  - 192.168.1.42:9392:9392
```

After changing the port binding, recreate the containers:

```bash
sudo docker compose -f /opt/openvas/compose.yaml up -d
```

You can also keep OpenVAS listening on all interfaces and restrict access with a firewall rule, for example with `ufw`:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 443 proto tcp
```

## HTTPS certificate

The default OpenVAS container setup uses a self-signed HTTPS certificate. Browsers will usually display a security warning for this certificate.

To avoid browser warnings, install a TLS certificate issued by a certificate authority trusted by browsers.

## Managing the HTTPS certificate

After Easy-OpenVAS has already been installed, the HTTPS certificate can be managed without reinstalling OpenVAS:

```bash
sudo ./certificate-installer.sh
```

By default, Easy-OpenVAS keeps the Greenbone self-signed certificate generated by the Greenbone containers.

A custom certificate must cover the OpenVAS FQDN actually used by the service in its DNS Subject Alternative Name.

Example:

```text
OpenVAS FQDN:
openvas.example.com

Certificate SAN:
DNS:openvas.example.com
```

To use an enterprise or publicly trusted certificate, choose:

```text
1. Install / replace custom certificate
```

The administrator only has to provide:

```text
Certificate / fullchain path
Private key path
OpenVAS FQDN
```

The script asks for the certificate or fullchain path, the private key path, and the OpenVAS FQDN. It validates the certificate, validates the private key, checks that they match, verifies that the certificate covers the OpenVAS FQDN, copies the files to `/opt/openvas/certs/`, applies secure permissions, updates the Greenbone nginx TLS configuration, and verifies the certificate actually presented by NGINX over HTTPS.

When the installation completes successfully, the original source certificate and key files provided by the administrator are no longer required by Easy-OpenVAS and may be removed by the administrator.

The same script can also:

- show the currently presented HTTPS certificate;
- replace an existing custom certificate with a new one;
- restore the original Greenbone self-signed certificate.

## Default credentials

```text
Username: admin
Password: admin
```

Change the default admin password after the first login. You can do this from the admin account menu in the top-right corner: `Settings > Password`, then enter the old password and the new password.

If the admin password is lost, you can reset it from the command line:

```bash
sudo docker exec -it greenbone-community-edition-gvmd-1 gvmd --user=admin --new-password='XXXXX'
```

## Mini OpenVAS configuration tutorial

Before configuring a scan, wait until the vulnerability feeds are fully synchronized. The first synchronization can take a **VERY LONG TIME** after the initial installation, and the vulnerability feed can potentially take **more than 2 hours** depending on the server performance, disk speed, RAM, and internet connection. Scans will not be possible until everything is fully loaded.

You can check the feed synchronization status in:

```text
Administration > Feed Status
```

If the feeds are not ready yet, the default scan configurations may not be available and task creation can fail.

To scan a host:

1. Go to `Configuration` > `Targets`.
2. Create a new target.
3. Enter a target name.
4. Enter the host IP address or DNS name to scan.
5. Save the target.
6. Go to `Scans` > `Tasks`.
7. Create a new task.
8. Select the target created previously.
9. Start the scan.

Create separate tasks when the scan policy is different, or when you want to organize scans by scope. For example, use different tasks for internal servers, external exposure, workstations, or critical assets.

When the scan is complete, open the task results and review the report. The report lists detected vulnerabilities, severity levels, affected services, and remediation guidance.


## Disclaimer

This script is provided as a proposal/example and was developed as part of a proof of concept (PoC). It has not been tested in a production environment. Before any use or deployment in production, users must take all necessary precautions, review and understand the code, adapt it to their own context, and thoroughly test it.


## License

This project is licensed under the GNU Affero General Public License v3.0 (`AGPL-3.0-only`).

You can use, copy, share, and modify this project. If you distribute a modified version, or make a modified version available as a network service, you must keep it under the AGPL and make the corresponding source code available to users.

Full license text: <https://www.gnu.org/licenses/agpl-3.0.html>
