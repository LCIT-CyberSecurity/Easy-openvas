import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "certificate-installer.sh"


COMPOSE = """services:
  gvm-config:
    image: registry.community.greenbone.net/community/gvm-config:latest
    environment:
      ENABLE_NGINX_CONFIG: true
      ENABLE_TLS_GENERATION: true
    volumes:
      - nginx_config_vol:/mnt/nginx/configs
      - nginx_certificates_vol:/mnt/nginx/certs

  nginx:
    image: registry.community.greenbone.net/community/nginx:latest
    ports:
      - 443:443
      - 9392:9392
    volumes:
      - nginx_config_vol:/etc/nginx/conf.d:ro
      - nginx_certificates_vol:/etc/nginx/certs:ro
      - gsa_data_vol:/usr/share/nginx/html:ro
    depends_on:
      gvm-config:
        condition: service_completed_successfully

volumes:
  nginx_config_vol:
  nginx_certificates_vol:
  gsa_data_vol:
"""


def run_cmd(args, *, env=None, input_text=None, cwd=REPO):
    merged_env = os.environ.copy()
    merged_env.update(env or {})
    merged_env.setdefault("NO_COLOR", "1")
    return subprocess.run(
        args,
        cwd=cwd,
        env=merged_env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def run_installer(command, *args, env=None, input_text=None):
    return run_cmd(
        ["bash", str(SCRIPT), "--test-command", command, *map(str, args)],
        env=env,
        input_text=input_text,
    )


def write_compose(base, content=COMPOSE):
    base.mkdir(parents=True, exist_ok=True)
    compose = base / "compose.yaml"
    compose.write_text(content)
    return compose


def write_mock_docker(path, *, config_exit=0, up_exit=0, ps_exit=0):
    log = path.parent / "docker.log"
    path.write_text(
        f"""#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "{log}"
action=""
for arg in "$@"; do
  case "$arg" in
    config|up|ps) action="$arg" ;;
  esac
done
if [[ "$action" == "config" ]]; then
  exit {config_exit}
fi
if [[ "$action" == "up" ]]; then
  exit {up_exit}
fi
if [[ "$action" == "ps" ]]; then
  echo mock-nginx
  exit {ps_exit}
fi
exit 0
"""
    )
    path.chmod(0o755)
    return log


def make_env(tmp_path, *, base=None, docker=None, presented_cert=None):
    base = base or tmp_path / "openvas"
    env = {
        "EASY_OPENVAS_BASE_DIR": str(base),
        "EASY_OPENVAS_SKIP_ROOT": "true",
        "EASY_OPENVAS_TEST_MODE": "true",
    }
    if docker:
        env["EASY_OPENVAS_DOCKER_CMD"] = str(docker)
    if presented_cert:
        env["EASY_OPENVAS_PRESENTED_CERT"] = str(presented_cert)
        env["EASY_OPENVAS_HTTPS_CERT_CMD"] = (
            'cp "$EASY_OPENVAS_PRESENTED_CERT" "$EASY_OPENVAS_CERT_OUTPUT"'
        )
    return env


def generate_cert(tmp_path, name, san, *, days=30):
    cert = tmp_path / f"{name}.crt"
    key = tmp_path / f"{name}.key"
    config = tmp_path / f"{name}.cnf"
    config.write_text(
        f"""[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = {san.replace("DNS:", "").split(",")[0].strip()}
[v3_req]
subjectAltName = {san}
"""
    )
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            str(days),
            "-keyout",
            str(key),
            "-out",
            str(cert),
            "-config",
            str(config),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    return cert, key


def generate_expired_cert(tmp_path):
    key = tmp_path / "expired.key"
    csr = tmp_path / "expired.csr"
    cert = tmp_path / "expired.crt"
    config = tmp_path / "expired.cnf"
    config.write_text(
        """[req]
distinguished_name = dn
prompt = no
[dn]
CN = openvas.client.fr
"""
    )
    subprocess.run(
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-config", config],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    subprocess.run(
        ["openssl", "x509", "-req", "-in", csr, "-signkey", key, "-out", cert, "-days", "0"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    return cert, key


class CertificateInstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_valid_certificate_exact_san(self):
        cert, key = generate_cert(self.tmp_path, "exact", "DNS:openvas.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] Certificate covers openvas.client.fr", result.stdout)

    def test_valid_certificate_wildcard_san(self):
        cert, key = generate_cert(self.tmp_path, "wildcard", "DNS:*.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] Certificate covers openvas.client.fr", result.stdout)

    def test_certificate_rejects_uncovered_fqdn(self):
        cert, key = generate_cert(self.tmp_path, "other", "DNS:other.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate does not cover openvas.client.fr", result.stderr)

    def test_invalid_certificate_and_invalid_key_are_rejected(self):
        bad_cert = self.tmp_path / "bad cert.pem"
        bad_key = self.tmp_path / "bad key.pem"
        bad_cert.write_text("not a certificate")
        bad_key.write_text("not a key")
        result = run_installer("validate-certificate", bad_cert, bad_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate PEM format invalid", result.stderr)

        cert, _ = generate_cert(self.tmp_path, "valid", "DNS:openvas.client.fr")
        result = run_installer("validate-certificate", cert, bad_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Private key format invalid", result.stderr)

    def test_expired_certificate_is_rejected(self):
        cert, key = generate_expired_cert(self.tmp_path)
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate has expired", result.stderr)

    def test_certificate_key_mismatch_is_rejected(self):
        cert, _ = generate_cert(self.tmp_path, "one", "DNS:openvas.client.fr")
        _, key = generate_cert(self.tmp_path, "two", "DNS:openvas.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate and private key do not match", result.stderr)

    def test_secure_copy_supports_absolute_and_space_paths(self):
        base = self.tmp_path / "openvas"
        cert_dir = self.tmp_path / "source files"
        cert_dir.mkdir()
        cert, key = generate_cert(cert_dir, "space name", "DNS:openvas.client.fr")
        result = run_installer("copy-certificate", cert.resolve(), key.resolve(), env=make_env(self.tmp_path, base=base))
        self.assertEqual(result.returncode, 0, result.stderr)
        cert_dest = base / "certs" / "server.cert.pem"
        key_dest = base / "certs" / "server.key"
        self.assertEqual(cert_dest.read_bytes(), cert.read_bytes())
        self.assertEqual(key_dest.read_bytes(), key.read_bytes())
        self.assertEqual(stat.S_IMODE((base / "certs").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(cert_dest.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(key_dest.stat().st_mode), 0o600)

    def test_prompted_install_supports_relative_path(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        cert, key = generate_cert(REPO, "relative-test-temp", "DNS:openvas.client.fr")
        try:
            env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=cert)
            result = run_installer(
                "install-custom",
                env=env,
                input_text=f"{cert.name}\n{key.resolve()}\nopenvas.client.fr\ny\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            cert.unlink(missing_ok=True)
            key.unlink(missing_ok=True)
            (REPO / "relative-test-temp.cnf").unlink(missing_ok=True)

    def test_compose_validation_rejects_missing_services_and_tls_structure(self):
        base = self.tmp_path / "openvas"
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        env = make_env(self.tmp_path, base=base, docker=docker)

        result = run_installer("validate-installation", env=env)
        self.assertNotEqual(result.returncode, 0)

        write_compose(base, COMPOSE.replace("  nginx:\n", "  web:\n"))
        result = run_installer("validate-installation", env=env)
        self.assertNotEqual(result.returncode, 0)

        write_compose(base, COMPOSE.replace("  gvm-config:\n", "  config:\n"))
        result = run_installer("validate-installation", env=env)
        self.assertNotEqual(result.returncode, 0)

        write_compose(base, COMPOSE.replace("      ENABLE_TLS_GENERATION: true\n", ""))
        result = run_installer("validate-installation", env=env)
        self.assertNotEqual(result.returncode, 0)

    def test_compose_custom_patch_is_idempotent_and_ro(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        env = make_env(self.tmp_path, base=base)
        self.assertEqual(run_installer("apply-custom", env=env).returncode, 0)
        self.assertEqual(run_installer("apply-custom", env=env).returncode, 0)
        content = (base / "compose.yaml").read_text()
        self.assertIn("ENABLE_TLS_GENERATION: false", content)
        self.assertEqual(content.count("/etc/nginx/certs/server.cert.pem:ro"), 1)
        self.assertEqual(content.count("/etc/nginx/certs/server.key:ro"), 1)
        self.assertNotIn("nginx_certificates_vol:/etc/nginx/certs:ro", content)

    def test_compose_self_signed_patch_is_idempotent(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        env = make_env(self.tmp_path, base=base)
        self.assertEqual(run_installer("apply-custom", env=env).returncode, 0)
        self.assertEqual(run_installer("apply-self-signed", env=env).returncode, 0)
        self.assertEqual(run_installer("apply-self-signed", env=env).returncode, 0)
        content = (base / "compose.yaml").read_text()
        self.assertIn("ENABLE_TLS_GENERATION: true", content)
        self.assertEqual(content.count("nginx_certificates_vol:/etc/nginx/certs:ro"), 1)
        self.assertNotIn("/etc/nginx/certs/server.cert.pem:ro", content)
        self.assertNotIn("/etc/nginx/certs/server.key:ro", content)

    def test_install_transitions_and_no_sensitive_output_or_destructive_docker(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        docker = self.tmp_path / "docker"
        log = write_mock_docker(docker)
        cert1, key1 = generate_cert(self.tmp_path, "custom1", "DNS:openvas.client.fr")
        cert2, key2 = generate_cert(self.tmp_path, "custom2", "DNS:openvas.client.fr")
        env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=cert1)

        input_one = f"{cert1}\n{key1}\nopenvas.client.fr\ny\n"
        result = run_installer("install-custom", env=env, input_text=input_one)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Certificate installation successful", result.stdout)
        self.assertNotIn(key1.read_text(), result.stdout)
        self.assertNotIn(key1.read_text(), result.stderr)

        result = run_installer("install-custom", env=env, input_text=input_one)
        self.assertEqual(result.returncode, 0, result.stderr)

        env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=cert2)
        input_two = f"{cert2}\n{key2}\nopenvas.client.fr\ny\n"
        result = run_installer("install-custom", env=env, input_text=input_two)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((base / "certs" / "server.cert.pem").read_bytes(), cert2.read_bytes())
        docker_log = log.read_text()
        self.assertNotIn("down -v", docker_log)
        self.assertNotIn("volume rm", docker_log)
        self.assertNotIn("system prune", docker_log)

    def test_restore_self_signed_transitions_and_removes_custom_files(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        cert, key = generate_cert(self.tmp_path, "custom", "DNS:openvas.client.fr")
        env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=cert)
        result = run_installer("install-custom", env=env, input_text=f"{cert}\n{key}\nopenvas.client.fr\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)

        result = run_installer("restore-self-signed", env=env, input_text="y\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Greenbone self-signed certificate restored successfully", result.stdout)
        self.assertFalse((base / "certs" / "server.cert.pem").exists())
        self.assertFalse((base / "certs" / "server.key").exists())

        result = run_installer("restore-self-signed", env=env, input_text="y\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rollback_on_compose_validation_failure(self):
        base = self.tmp_path / "openvas"
        compose = write_compose(base)
        before = compose.read_text()
        docker = self.tmp_path / "docker"
        write_mock_docker(docker, config_exit=1)
        cert, key = generate_cert(self.tmp_path, "custom", "DNS:openvas.client.fr")
        env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=cert)
        result = run_installer("install-custom", env=env, input_text=f"{cert}\n{key}\nopenvas.client.fr\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(compose.read_text(), before)

    def test_rollback_on_nginx_start_failure(self):
        base = self.tmp_path / "openvas"
        compose = write_compose(base)
        before = compose.read_text()
        docker = self.tmp_path / "docker"
        write_mock_docker(docker, up_exit=1)
        cert, key = generate_cert(self.tmp_path, "custom", "DNS:openvas.client.fr")
        env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=cert)
        result = run_installer("install-custom", env=env, input_text=f"{cert}\n{key}\nopenvas.client.fr\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(compose.read_text(), before)

    def test_rollback_on_wrong_presented_certificate(self):
        base = self.tmp_path / "openvas-wrong-cert"
        compose = write_compose(base)
        before = compose.read_text()
        docker = self.tmp_path / "docker-wrong-cert"
        write_mock_docker(docker)
        cert, key = generate_cert(self.tmp_path, "custom", "DNS:openvas.client.fr")
        wrong_cert, _ = generate_cert(self.tmp_path, "wrong", "DNS:openvas.client.fr")
        env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=wrong_cert)
        result = run_installer("install-custom", env=env, input_text=f"{cert}\n{key}\nopenvas.client.fr\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(compose.read_text(), before)

    def test_show_current_certificate_uses_presented_certificate(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        cert, _ = generate_cert(self.tmp_path, "presented", "DNS:openvas.client.fr")
        env = make_env(self.tmp_path, base=base, docker=docker, presented_cert=cert)
        result = run_installer("show-current", env=env, input_text="openvas.client.fr\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Current HTTPS certificate", result.stdout)
        self.assertIn("Status.............. [OK] Certificate valid", result.stdout)

    def test_tests_do_not_create_real_opt_openvas(self):
        self.assertFalse(Path("/opt/openvas/certs/server.key").exists())
        self.assertFalse(Path("/opt/openvas/certs/server.cert.pem").exists())
        self.assertIsNone(shutil.which("Openvas-installer.sh"))


if __name__ == "__main__":
    unittest.main()
