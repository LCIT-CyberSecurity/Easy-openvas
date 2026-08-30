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

    def write_docker(self, exit_code):
        docker = self.tmp_path / "docker"
        docker.write_text(f"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "{self.tmp_path / 'docker.log'}"
exit {exit_code}
""")
        docker.chmod(0o755)
        return docker

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
        docker = self.write_docker(0)
        result = self.run_installer("validate-compose", compose, env={"EASY_OPENVAS_DOCKER_CMD": str(docker)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] Docker Compose configuration valid", result.stdout)

        docker = self.write_docker(1)
        result = self.run_installer("validate-compose", compose, env={"EASY_OPENVAS_DOCKER_CMD": str(docker)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[ERROR] Docker Compose configuration is invalid.", result.stderr)

    def test_safety_constraints_for_tests(self):
        self.assertFalse(Path("/opt/openvas/compose.yaml").exists())


if __name__ == "__main__":
    unittest.main()
