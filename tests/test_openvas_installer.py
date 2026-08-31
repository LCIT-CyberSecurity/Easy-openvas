import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "Openvas-installer.sh"
COMPOSE = """services:
  gvm-config:
    image: registry.community.greenbone.net/community/gvm-config:latest
    environment:
      ENABLE_NGINX_CONFIG: true
      ENABLE_TLS_GENERATION: true
    volumes:
      - nginx_config_vol:/mnt/nginx/configs

  nginx:
    image: registry.community.greenbone.net/community/nginx:latest
    environment:
      NGINX_HOST: "do-not-touch.example.com"
    ports:
      - 443:443

volumes:
  nginx_config_vol:
"""


COMPOSE_WITH_EXISTING_FQDN = """services:
  gvm-config:
    image: registry.community.greenbone.net/community/gvm-config:latest
    environment:
      ENABLE_NGINX_CONFIG: true
      NGINX_HOST: "old.example.com"
      ENABLE_TLS_GENERATION: true
      NGINX_ACCESS_CONTROL_ALLOW_ORIGIN_HEADER: "https://old.example.com"
    volumes:
      - nginx_config_vol:/mnt/nginx/configs

  nginx:
    image: registry.community.greenbone.net/community/nginx:latest
    environment:
      NGINX_HOST: "do-not-touch.example.com"
    ports:
      - 443:443
"""


class OpenvasInstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_installer(self, command, *args, env=None, input_text=None):
        merged_env = os.environ.copy()
        merged_env.update(env or {})
        return subprocess.run(
            ["bash", str(SCRIPT), "--test-command", command, *map(str, args)],
            cwd=REPO,
            env=merged_env,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def write_compose(self, content=COMPOSE):
        compose = self.tmp_path / "compose.yaml"
        compose.write_text(content)
        return compose

    def write_getent(self, body):
        getent = self.tmp_path / "getent"
        getent.write_text(body)
        getent.chmod(0o755)
        return getent

    def write_docker(
        self,
        *,
        info_exit=0,
        compose_version_exit=0,
        config_exit=0,
        context_show="",
        context_endpoint="",
        compose_projects="",
        label_projects="",
        docker_root="",
    ):
        docker = self.tmp_path / "docker"
        docker.write_text(f"""#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "{self.tmp_path / 'docker.log'}"
if [[ "${{1:-}}" == "--version" ]]; then
  printf 'Docker version 27.0.0, build mock\n'
  exit 0
fi
if [[ "${{1:-}}" == "info" && "${{2:-}}" == "--format" ]]; then
  printf '{docker_root}\n'
  exit {info_exit}
fi
if [[ "${{1:-}}" == "info" ]]; then
  exit {info_exit}
fi
if [[ "${{1:-}}" == "context" && "${{2:-}}" == "show" ]]; then
  printf '{context_show}\n'
  exit 0
fi
if [[ "${{1:-}}" == "context" && "${{2:-}}" == "inspect" ]]; then
  printf '{context_endpoint}\n'
  exit 0
fi
if [[ "${{1:-}}" == "compose" && "${{2:-}}" == "version" ]]; then
  printf 'Docker Compose version v2.29.0\n'
  exit {compose_version_exit}
fi
if [[ "${{1:-}}" == "compose" && "${{2:-}}" == "ls" ]]; then
  printf '{compose_projects}\n'
  exit 0
fi
if [[ "${{1:-}}" == "compose" ]]; then
  action=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "-q" ]]; then
      printf 'mock-%s\n' "$arg"
      exit 0
    fi
    if [[ "$arg" == "config" || "$arg" == "pull" || "$arg" == "up" || "$arg" == "ps" || "$arg" == "logs" ]]; then
      action="$arg"
    fi
    previous="$arg"
  done
  if [[ "$action" == "config" ]]; then exit {config_exit}; fi
  if [[ "$action" == "ps" ]]; then printf 'mock service status\n'; fi
  exit 0
fi
if [[ "${{1:-}}" == "ps" ]]; then
  printf '{label_projects}\n'
  exit 0
fi
if [[ "${{1:-}}" == "inspect" ]]; then
  printf 'healthy\n'
  exit 0
fi
exit 0
""")
        docker.chmod(0o755)
        return docker

    def write_os_release(self, *, os_id="debian", version_id="13", codename="trixie"):
        os_release = self.tmp_path / f"os-release-{os_id}-{version_id}"
        os_release.write_text(f'ID={os_id}\nVERSION_ID="{version_id}"\nVERSION_CODENAME={codename}\n')
        return os_release

    def write_ss(self, *used_ports):
        ss = self.tmp_path / "ss"
        lines = ["State Recv-Q Send-Q Local Address:Port Peer Address:Port Process"]
        for port in used_ports:
            lines.append(f"LISTEN 0 4096 0.0.0.0:{port} 0.0.0.0:*")
        quoted_lines = " ".join(repr(line) for line in lines)
        ss.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' {quoted_lines}\n")
        ss.chmod(0o755)
        return ss

    def write_forbidden_command(self, name):
        command = self.tmp_path / name
        command.write_text(f"""#!/usr/bin/env bash
printf '%s %s\n' "{name}" "$*" >> "{self.tmp_path / 'forbidden.log'}"
exit 99
""")
        command.chmod(0o755)
        return command

    def write_dpkg_query(self, *installed):
        dpkg = self.tmp_path / "dpkg-query"
        cases = "\n".join(f"    {pkg}) printf 'install ok installed' ; exit 0 ;;" for pkg in installed)
        dpkg.write_text(f"""#!/usr/bin/env bash
pkg="${{@: -1}}"
case "$pkg" in
{cases}
esac
exit 1
""")
        dpkg.chmod(0o755)
        return dpkg

    def write_nproc(self, cpus=4):
        nproc = self.tmp_path / "nproc"
        nproc.write_text(f"#!/usr/bin/env bash\nprintf '{cpus}\n'\n")
        nproc.chmod(0o755)
        return nproc

    def write_df(self, available_gb=80):
        df = self.tmp_path / "df"
        available_kb = available_gb * 1024 * 1024
        df.write_text(f"""#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/mock 104857600 1 {available_kb} 1%% /mock\n'
""")
        df.chmod(0o755)
        return df

    def write_meminfo(self, ram_gb=8):
        meminfo = self.tmp_path / "meminfo"
        meminfo.write_text(f"MemTotal:       {ram_gb * 1024 * 1024} kB\n")
        return meminfo

    def menu_env(
        self,
        *,
        docker=None,
        docker_present="true",
        os_release=None,
        ss=None,
        compose_source=None,
        getent=None,
        dpkg_query=None,
        nproc=None,
        df=None,
        meminfo=None,
    ):
        compose_source = compose_source or self.write_compose()
        getent = getent or self.write_getent("#!/usr/bin/env bash\nexit 2\n")
        env = {
            "EASY_OPENVAS_BASE_DIR": str(self.tmp_path / "openvas"),
            "EASY_OPENVAS_COMPOSE_SOURCE": str(compose_source),
            "EASY_OPENVAS_DF_CMD": str(df or self.write_df()),
            "EASY_OPENVAS_DOCKER_CMD": str(docker or self.write_docker()),
            "EASY_OPENVAS_DOCKER_PRESENT": docker_present,
            "EASY_OPENVAS_DPKG_QUERY_CMD": str(dpkg_query or self.write_dpkg_query()),
            "EASY_OPENVAS_GETENT_CMD": str(getent),
            "EASY_OPENVAS_HEALTH_MAX_ATTEMPTS": "1",
            "EASY_OPENVAS_HEALTH_SLEEP_SECONDS": "0",
            "EASY_OPENVAS_MEMINFO": str(meminfo or self.write_meminfo()),
            "EASY_OPENVAS_NPROC_CMD": str(nproc or self.write_nproc()),
            "EASY_OPENVAS_OS_RELEASE": str(os_release or self.write_os_release()),
            "EASY_OPENVAS_SERVER_FQDN": "docker01.client.fr",
            "EASY_OPENVAS_SERVER_IP": "192.0.2.25",
            "EASY_OPENVAS_SKIP_DOCKER_INSTALL": "true",
            "EASY_OPENVAS_SKIP_ROOT": "true",
            "EASY_OPENVAS_SS_CMD": str(ss or self.write_ss()),
        }
        return env

    def test_suggested_fqdn_removes_only_first_label(self):
        cases = {
            "docker01.client.fr": "openvas.client.fr",
            "docker01.infra.client.fr": "openvas.infra.client.fr",
            "docker01": "",
            "192.168.1.25": "",
        }
        for host, expected in cases.items():
            with self.subTest(host=host):
                result = self.run_installer("suggest-fqdn", host)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_admin_fqdn_choices_and_normalization(self):
        valid = [
            "toto.fr",
            "host.domain.fr",
            "scan.toto.fr",
            "openvas.toto.fr",
            "scan.security.toto.fr",
            "vuln.internal.example.com",
        ]
        for fqdn in valid:
            with self.subTest(fqdn=fqdn):
                result = self.run_installer("validate-fqdn", fqdn)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, fqdn)

        result = self.run_installer("validate-fqdn", "SCAN.SECURITY.TOTO.FR.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "scan.security.toto.fr")

    def test_invalid_fqdn_values_are_rejected(self):
        invalid = [
            "https://openvas.client.fr",
            "http://openvas.client.fr",
            "openvas.client.fr/",
            "openvas.client.fr:443",
            "*.client.fr",
            "192.168.1.25",
            "10.0.0.1",
            "127.0.0.1",
        ]
        for fqdn in invalid:
            with self.subTest(fqdn=fqdn):
                result = self.run_installer("validate-fqdn", fqdn)
                self.assertNotEqual(result.returncode, 0)

    def test_prompt_accepts_default_or_custom_complete_fqdn(self):
        result = self.run_installer("prompt-fqdn", "docker01.client.fr", input_text="\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "openvas.client.fr\n")
        self.assertIn("OpenVAS FQDN [openvas.client.fr]:", result.stderr)

        result = self.run_installer("prompt-fqdn", "docker01.client.fr", input_text="scan.security.toto.fr\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "scan.security.toto.fr\n")

        result = self.run_installer("prompt-fqdn", "docker01", input_text="scan.toto.fr\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "scan.toto.fr\n")
        self.assertIn("OpenVAS FQDN:\n> ", result.stderr)

        result = self.run_installer("prompt-fqdn", "192.168.1.25", input_text="scan.toto.fr\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "scan.toto.fr\n")
        self.assertIn("OpenVAS FQDN:\n> ", result.stderr)
        self.assertNotIn("openvas.168.1.25", result.stderr)

    def test_prompt_reasks_after_invalid_fqdn(self):
        result = self.run_installer("prompt-fqdn", "docker01.client.fr", input_text="https://openvas.client.fr\ntoto.fr\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "toto.fr\n")
        self.assertIn("[ERROR] Invalid OpenVAS FQDN.", result.stderr)

    def test_dns_check_reports_single_multiple_deduplicated_and_unresolved(self):
        getent = self.write_getent("""#!/usr/bin/env bash
if [[ "$1" == "ahostsv4" ]]; then
  case "$2" in
    one.example.com) printf '192.0.2.10 STREAM one.example.com\n' ; exit 0 ;;
    many.example.com) printf '192.0.2.10 STREAM many.example.com\n192.0.2.10 DGRAM many.example.com\n192.0.2.11 STREAM many.example.com\n' ; exit 0 ;;
  esac
fi
exit 2
""")
        env = {"EASY_OPENVAS_GETENT_CMD": str(getent)}

        result = self.run_installer("dns-check", "one.example.com", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] DNS name one.example.com resolves to 192.0.2.10", result.stdout)

        result = self.run_installer("dns-check", "many.example.com", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] DNS name many.example.com resolves to 192.0.2.10 192.0.2.11", result.stdout)

        result = self.run_installer("dns-check", "missing.example.com", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[WARNING] DNS name missing.example.com does not currently resolve.", result.stdout)
        self.assertIn("[WARNING] Create or verify the DNS entry", result.stdout)

    def test_dns_check_falls_back_to_getent_hosts(self):
        getent = self.write_getent("""#!/usr/bin/env bash
if [[ "$1" == "hosts" && "$2" == "fallback.example.com" ]]; then
  printf '198.51.100.25 fallback.example.com\n'
  exit 0
fi
exit 2
""")
        result = self.run_installer("dns-check", "fallback.example.com", env={"EASY_OPENVAS_GETENT_CMD": str(getent)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("198.51.100.25", result.stdout)

    def test_configure_compose_adds_fqdn_to_gvm_config_only(self):
        compose = self.write_compose()
        result = self.run_installer("configure-compose", compose, "scan.security.toto.fr")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = compose.read_text()
        self.assertIn("      ENABLE_NGINX_CONFIG: true\n", content)
        self.assertIn("      ENABLE_TLS_GENERATION: true\n", content)
        self.assertIn('      NGINX_HOST: "scan.security.toto.fr"\n', content)
        self.assertIn('      NGINX_ACCESS_CONTROL_ALLOW_ORIGIN_HEADER: "https://scan.security.toto.fr"\n', content)
        self.assertIn('      NGINX_HOST: "do-not-touch.example.com"\n', content)

    def test_configure_compose_preserves_file_mode(self):
        for mode in (0o644, 0o640):
            with self.subTest(mode=oct(mode)):
                compose = self.write_compose()
                compose.chmod(mode)
                result = self.run_installer("configure-compose", compose, "scan.security.toto.fr")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(compose.stat().st_mode & 0o777, mode)

    def test_configure_compose_replaces_existing_values_without_duplicates(self):
        compose = self.write_compose(COMPOSE_WITH_EXISTING_FQDN)
        result = self.run_installer("configure-compose", compose, "scan.security.toto.fr")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = compose.read_text()
        self.assertNotIn("old.example.com", content)
        self.assertEqual(content.count("NGINX_HOST:"), 2)
        self.assertEqual(content.count("NGINX_ACCESS_CONTROL_ALLOW_ORIGIN_HEADER:"), 1)
        self.assertEqual(content.count('NGINX_HOST: "scan.security.toto.fr"'), 1)

    def test_configure_compose_rejects_unexpected_structure(self):
        compose = self.write_compose(COMPOSE.replace("  gvm-config:\n", "  config:\n"))
        result = self.run_installer("configure-compose", compose, "scan.security.toto.fr")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported Greenbone Compose structure", result.stderr)

    def test_docker_compose_validation_ok_and_ko(self):
        compose = self.write_compose()
        docker = self.write_docker(config_exit=0)
        result = self.run_installer("validate-compose", compose, env={"EASY_OPENVAS_DOCKER_CMD": str(docker)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] Docker Compose configuration valid", result.stdout)

        docker = self.write_docker(config_exit=1)
        result = self.run_installer("validate-compose", compose, env={"EASY_OPENVAS_DOCKER_CMD": str(docker)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[ERROR] Docker Compose configuration is invalid.", result.stderr)


    def test_menu_option_3_exits_and_invalid_choice_reprompts(self):
        result = self.run_installer("menu", env=self.menu_env(), input_text="3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1. Install OpenVAS on a fresh Debian 13 server", result.stdout)
        self.assertIn("2. Install OpenVAS on an existing Docker server", result.stdout)
        self.assertIn("3. Exit", result.stdout)

        result = self.run_installer("menu", env=self.menu_env(), input_text="bad\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[WARNING] Invalid choice.", result.stdout)

    def test_fresh_debian13_without_docker_installs_docker_then_deploys(self):
        docker = self.write_docker()
        result = self.run_installer("menu", env=self.menu_env(docker=docker, docker_present="false"), input_text="1\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] Debian 13 detected", result.stdout)
        self.assertIn("[OK] No existing Docker installation detected", result.stdout)
        self.assertIn("[OK] No conflicting Docker CE packages detected", result.stdout)
        self.assertIn("[INFO] Installing Docker for Easy-OpenVAS...", result.stdout)
        docker_log = (self.tmp_path / "docker.log").read_text()
        self.assertIn("compose -f", docker_log)
        self.assertIn("pull", docker_log)

    def test_fresh_mode_rejects_non_debian13_before_docker_or_deploy(self):
        for os_release in (self.write_os_release(version_id="12", codename="bookworm"), self.write_os_release(os_id="ubuntu", version_id="24.04", codename="noble")):
            with self.subTest(os_release=os_release.read_text()):
                docker = self.write_docker()
                result = self.run_installer("menu", env=self.menu_env(docker=docker, docker_present="false", os_release=os_release), input_text="1\n3\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("[ERROR] Fresh server mode currently supports Debian 13 only.", result.stderr)
                self.assertIn("[INFO] No system changes have been made.", result.stdout)
                self.assertFalse((self.tmp_path / "docker.log").exists())

    def test_fresh_mode_refuses_operational_existing_docker(self):
        docker = self.write_docker()
        result = self.run_installer("menu", env=self.menu_env(docker=docker, docker_present="true"), input_text="1\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[WARNING] An operational Docker installation already exists.", result.stdout)
        self.assertIn("[INFO] Use option 2 to deploy Easy-OpenVAS on the existing Docker server.", result.stdout)
        docker_log = (self.tmp_path / "docker.log").read_text()
        self.assertEqual(docker_log, "info\n")

    def test_fresh_mode_refuses_installed_but_broken_docker(self):
        docker = self.write_docker(info_exit=1)
        result = self.run_installer("menu", env=self.menu_env(docker=docker, docker_present="true"), input_text="1\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[ERROR] Docker is installed but the Docker daemon is not operational.", result.stderr)
        self.assertIn("[INFO] Fresh Debian 13 installation mode will not modify this Docker installation.", result.stdout)
        docker_log = (self.tmp_path / "docker.log").read_text()
        self.assertEqual(docker_log, "info\n")

    def test_fresh_mode_rejects_conflicting_docker_ce_packages_non_destructively(self):
        for package in ("containerd", "runc", "podman-docker"):
            with self.subTest(package=package):
                dpkg = self.write_dpkg_query(package)
                docker = self.write_docker()
                result = self.run_installer(
                    "menu",
                    env=self.menu_env(docker=docker, docker_present="false", dpkg_query=dpkg),
                    input_text="1\n3\n",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("[ERROR] Conflicting container packages were detected:", result.stderr)
                self.assertIn(f"  {package}", result.stderr)
                self.assertIn("[INFO] Easy-OpenVAS will not remove existing container software automatically.", result.stdout)
                self.assertIn("[INFO] No existing container software has been modified.", result.stdout)
                self.assertFalse((self.tmp_path / "docker.log").exists())

    def test_fresh_mode_does_not_block_podman_command_without_package_conflict(self):
        podman = self.tmp_path / "podman"
        podman.write_text("#!/usr/bin/env bash\nexit 0\n")
        podman.chmod(0o755)
        docker = self.write_docker()
        env = self.menu_env(docker=docker, docker_present="false")
        env["PATH"] = f"{self.tmp_path}:{os.environ['PATH']}"
        result = self.run_installer("menu", env=env, input_text="1\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] No conflicting Docker CE packages detected", result.stdout)
        self.assertIn("Installation completed", result.stdout)

    def test_existing_docker_mode_requires_docker(self):
        result = self.run_installer("menu", env=self.menu_env(docker_present="false"), input_text="2\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[ERROR] Docker is not installed on this server.", result.stderr)
        self.assertIn("[INFO] Use option 1 if this is a fresh Debian 13 server.", result.stdout)

    def test_existing_docker_mode_rejects_bad_daemon_or_missing_compose(self):
        docker = self.write_docker(info_exit=1)
        result = self.run_installer("menu", env=self.menu_env(docker=docker), input_text="2\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[ERROR] Docker is installed but the Docker daemon is not operational.", result.stderr)
        self.assertIn("[INFO] Existing Docker installation has not been modified.", result.stdout)

        docker = self.write_docker(compose_version_exit=1)
        result = self.run_installer("menu", env=self.menu_env(docker=docker), input_text="2\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[ERROR] Docker is operational but Docker Compose v2 is not available.", result.stderr)
        self.assertIn("[INFO] Existing Docker installation has not been modified.", result.stdout)

    def test_existing_docker_mode_allows_non_debian_when_docker_is_ready(self):
        docker = self.write_docker()
        ubuntu = self.write_os_release(os_id="ubuntu", version_id="24.04", codename="noble")
        result = self.run_installer("menu", env=self.menu_env(docker=docker, os_release=ubuntu), input_text="2\ny\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Existing Docker preflight", result.stdout)
        self.assertIn("[OK] Local Docker endpoint", result.stdout)
        self.assertIn("[OK] No existing Greenbone project detected", result.stdout)
        self.assertIn("[OK] Resource checks completed", result.stdout)
        self.assertIn("Deploy Easy-OpenVAS on this Docker server? [y/N]:", result.stdout)
        self.assertIn("Installation completed", result.stdout)

    def test_existing_docker_mode_rejects_remote_docker_host(self):
        docker = self.write_docker()
        env = self.menu_env(docker=docker)
        env["DOCKER_HOST"] = "tcp://docker.example.com:2376"
        result = self.run_installer("menu", env=env, input_text="2\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[ERROR] The active Docker context points to a remote Docker daemon.", result.stderr)
        self.assertFalse((self.tmp_path / "openvas" / "compose.yaml").exists())

    def test_existing_docker_mode_rejects_remote_context(self):
        docker = self.write_docker(context_show="remote", context_endpoint="ssh://docker.example.com")
        result = self.run_installer("menu", env=self.menu_env(docker=docker), input_text="2\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[ERROR] The active Docker context points to a remote Docker daemon.", result.stderr)
        self.assertFalse((self.tmp_path / "openvas" / "compose.yaml").exists())

    def test_existing_docker_mode_rejects_existing_greenbone_project(self):
        for kwargs in ({"compose_projects": "greenbone-community-edition"}, {"label_projects": "openvas"}):
            with self.subTest(kwargs=kwargs):
                docker = self.write_docker(**kwargs)
                result = self.run_installer("menu", env=self.menu_env(docker=docker), input_text="2\n3\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("[ERROR] An existing Greenbone/OpenVAS Docker project was detected.", result.stderr)
                self.assertIn("[INFO] Existing containers, volumes and networks have not been modified.", result.stdout)
                self.assertFalse((self.tmp_path / "openvas" / "compose.yaml").exists())

    def test_existing_docker_preflight_cancels_by_default(self):
        docker = self.write_docker()
        result = self.run_installer("menu", env=self.menu_env(docker=docker), input_text="2\n\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Deploy Easy-OpenVAS on this Docker server? [y/N]:", result.stdout)
        self.assertIn("[INFO] Deployment cancelled.", result.stdout)
        self.assertIn("[INFO] Existing Docker environment has not been modified.", result.stdout)
        self.assertFalse((self.tmp_path / "openvas" / "compose.yaml").exists())

    def test_resource_checks_fail_below_minimum_and_warn_below_recommended(self):
        low = self.run_installer(
            "resources",
            "existing",
            env=self.menu_env(nproc=self.write_nproc(1), meminfo=self.write_meminfo(2), df=self.write_df(10)),
        )
        self.assertNotEqual(low.returncode, 0)
        self.assertIn("[ERROR] Insufficient system resources for Greenbone deployment.", low.stderr)

        warned = self.run_installer(
            "resources",
            "existing",
            env=self.menu_env(nproc=self.write_nproc(2), meminfo=self.write_meminfo(4), df=self.write_df(20)),
        )
        self.assertEqual(warned.returncode, 0, warned.stderr)
        self.assertIn("[WARNING] Available resources are below Greenbone recommended values.", warned.stdout)
        self.assertIn("[OK] Resource checks completed", warned.stdout)

    def test_port_checks_stop_before_deployment(self):
        for port in (443, 9392):
            with self.subTest(port=port):
                docker = self.write_docker()
                result = self.run_installer("menu", env=self.menu_env(docker=docker, ss=self.write_ss(port)), input_text="2\n\n3\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"[ERROR] TCP port {port} is already in use.", result.stderr)
                self.assertIn("[INFO] No existing service or container has been modified.", result.stdout)
                docker_log = (self.tmp_path / "docker.log").read_text()
                self.assertNotIn("pull", docker_log)
                self.assertFalse((self.tmp_path / "openvas" / "compose.yaml").exists())

    def test_existing_openvas_installation_is_not_overwritten(self):
        base = self.tmp_path / "openvas"
        compose = self.write_compose()
        base.mkdir()
        existing = base / "compose.yaml"
        existing.write_text("existing compose\n")
        docker = self.write_docker()
        result = self.run_installer("menu", env=self.menu_env(docker=docker, compose_source=compose), input_text="2\n\n3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[ERROR] An existing Easy-OpenVAS installation was detected", result.stderr)
        self.assertEqual(existing.read_text(), "existing compose\n")

    def test_installer_contains_no_automatic_destructive_remediation(self):
        script = SCRIPT.read_text()
        forbidden = [
            "apt remove",
            "apt purge",
            "apt autoremove",
            "systemctl stop docker",
            "systemctl restart docker",
            "docker system prune",
            "docker container prune",
            "docker image prune",
            "docker volume prune",
            "docker network prune",
            "docker compose down -v",
            "docker stop",
            "docker rm",
        ]
        for command in forbidden:
            with self.subTest(command=command):
                self.assertNotIn(command, script)

    def test_existing_docker_mode_does_not_run_destructive_commands(self):
        docker = self.write_docker()
        for name in ("apt", "systemctl"):
            self.write_forbidden_command(name)
        env = self.menu_env(docker=docker)
        env["PATH"] = f"{self.tmp_path}:{os.environ['PATH']}"
        result = self.run_installer("menu", env=env, input_text="2\ny\n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.tmp_path / "forbidden.log").exists())
        docker_log = (self.tmp_path / "docker.log").read_text()
        forbidden = [
            "system prune",
            "container prune",
            "image prune",
            "volume prune",
            "network prune",
            "compose down -v",
            "stop other-container",
            "rm other-container",
        ]
        for command in forbidden:
            self.assertNotIn(command, docker_log)

    def test_safety_constraints_for_tests(self):
        self.assertFalse(Path("/opt/openvas/compose.yaml").exists())


if __name__ == "__main__":
    unittest.main()
