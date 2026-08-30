import os
import shlex
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


CUSTOM_BLOCK = """      # Greenbone default self-signed certificate:
      # - nginx_certificates_vol:/etc/nginx/certs:ro

      # Easy-OpenVAS custom certificate:
      - {certs}:/etc/nginx/certs:ro
"""


SELF_SIGNED_BLOCK = """      # Greenbone default self-signed certificate:
      - nginx_certificates_vol:/etc/nginx/certs:ro

      # Easy-OpenVAS custom certificate:
      # - {certs}:/etc/nginx/certs:ro
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


def write_mock_docker(path, *, config_exit=0, up_exit=0, ps_output="mock-nginx", inspect_status="running"):
    log = path.parent / f"{path.name}.log"
    path.write_text(
        f"""#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "{log}"
action=""
for arg in "$@"; do
  case "$arg" in
    config|up|ps|inspect) action="$arg" ;;
  esac
done
case "$action" in
  config) exit {config_exit} ;;
  up) exit {up_exit} ;;
  ps) printf '%s\n' "{ps_output}"; exit 0 ;;
  inspect) printf '%s\n' "{inspect_status}"; exit 0 ;;
esac
exit 0
"""
    )
    path.chmod(0o755)
    return log


def write_https_helper(path, *certs):
    attempts = path.parent / f"{path.name}.attempts"
    quoted = " ".join(shlex.quote(str(cert)) for cert in certs)
    path.write_text(
        f"""#!/usr/bin/env bash
set -eu
attempt_file="{attempts}"
attempt=0
if [[ -f "$attempt_file" ]]; then
  attempt="$(cat "$attempt_file")"
fi
attempt=$((attempt + 1))
printf '%s' "$attempt" > "$attempt_file"
set -- {quoted}
index="$attempt"
if (( index > $# )); then
  index="$#"
fi
if (( index < 1 )); then
  exit 1
fi
cert="${{!index}}"
cp "$cert" "$EASY_OPENVAS_CERT_OUTPUT"
"""
    )
    path.chmod(0o755)
    return attempts


def make_env(tmp_path, *, base=None, docker=None, https_helper=None):
    base = base or tmp_path / "openvas"
    env = {
        "EASY_OPENVAS_BASE_DIR": str(base),
        "EASY_OPENVAS_SKIP_ROOT": "true",
        "EASY_OPENVAS_HTTPS_RETRY_DELAY": "0",
    }
    if docker:
        env["EASY_OPENVAS_DOCKER_CMD"] = str(docker)
    if https_helper:
        env["EASY_OPENVAS_HTTPS_CERT_CMD"] = str(https_helper)
    return env


def openssl(*args):
    subprocess.run(["openssl", *map(str, args)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)


def generate_self_signed_cert(tmp_path, name, san, *, days=90):
    tmp_path.mkdir(parents=True, exist_ok=True)
    cert = tmp_path / f"{name}.crt"
    key = tmp_path / f"{name}.key"
    config = tmp_path / f"{name}.cnf"
    cn = san.replace("DNS:", "").replace("IP:", "").split(",")[0].strip()
    config.write_text(
        f"""[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = {cn}
[v3_req]
subjectAltName = {san}
"""
    )
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", days, "-keyout", key, "-out", cert, "-config", config)
    return cert, key


def generate_signed_leaf(tmp_path, name, san, *, start="250101000000Z", end="300101000000Z"):
    ca_cert, ca_key = generate_self_signed_cert(tmp_path, f"{name}-ca", "DNS:ca.local")
    ca_dir = tmp_path / f"{name}-ca-db"
    ca_dir.mkdir()
    (ca_dir / "newcerts").mkdir()
    (ca_dir / "index.txt").write_text("")
    (ca_dir / "serial").write_text("1000\n")
    leaf_key = tmp_path / f"{name}.key"
    csr = tmp_path / f"{name}.csr"
    cert = tmp_path / f"{name}.crt"
    req_conf = tmp_path / f"{name}-req.cnf"
    ca_conf = tmp_path / f"{name}-ca.cnf"
    ext_conf = tmp_path / f"{name}-ext.cnf"
    req_conf.write_text("""[req]
distinguished_name = dn
prompt = no
[dn]
CN = openvas.client.fr
""")
    ca_conf.write_text(f"""[ca]
default_ca = local_ca
[local_ca]
database = {ca_dir / 'index.txt'}
new_certs_dir = {ca_dir / 'newcerts'}
certificate = {ca_cert}
private_key = {ca_key}
serial = {ca_dir / 'serial'}
default_md = sha256
policy = policy_any
copy_extensions = copy
unique_subject = no
[policy_any]
commonName = supplied
""")
    ext_conf.write_text(f"subjectAltName={san}\n")
    openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", leaf_key, "-out", csr, "-config", req_conf)
    openssl(
        "ca",
        "-batch",
        "-config",
        ca_conf,
        "-in",
        csr,
        "-out",
        cert,
        "-startdate",
        start,
        "-enddate",
        end,
        "-extfile",
        ext_conf,
    )
    return cert, leaf_key

def active_mounts(content):
    return [line.strip() for line in content.splitlines() if line.strip().startswith("-") and "/etc/nginx/certs:ro" in line]


class CertificateInstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_valid_certificate_exact_san(self):
        cert, key = generate_self_signed_cert(self.tmp_path, "exact", "DNS:openvas.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] Certificate valid for openvas.client.fr", result.stdout)

    def test_invalid_certificate_and_invalid_key_are_rejected(self):
        bad_cert = self.tmp_path / "bad cert.pem"
        bad_key = self.tmp_path / "bad key.pem"
        bad_cert.write_text("not a certificate")
        bad_key.write_text("not a key")
        result = run_installer("validate-certificate", bad_cert, bad_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate PEM format invalid", result.stderr)

        cert, _ = generate_self_signed_cert(self.tmp_path, "valid", "DNS:openvas.client.fr")
        result = run_installer("validate-certificate", cert, bad_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Private key format invalid", result.stderr)

    def test_certificate_key_mismatch_is_rejected(self):
        cert, _ = generate_self_signed_cert(self.tmp_path, "one", "DNS:openvas.client.fr")
        _, key = generate_self_signed_cert(self.tmp_path, "two", "DNS:openvas.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate and private key do not match", result.stderr)

    def test_not_before_future_and_expired_certificates_are_rejected(self):
        future_cert, future_key = generate_signed_leaf(self.tmp_path, "future", "DNS:openvas.client.fr", start="300101000000Z", end="310101000000Z")
        result = run_installer("validate-certificate", future_cert, future_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate is not valid yet", result.stderr)

        expired_cert, expired_key = generate_signed_leaf(self.tmp_path, "expired", "DNS:openvas.client.fr", start="200101000000Z", end="210101000000Z")
        result = run_installer("validate-certificate", expired_cert, expired_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate has expired", result.stderr)

    def test_san_exact_wildcard_absent_and_wrong_fqdn(self):
        cert, key = generate_self_signed_cert(self.tmp_path, "wildcard", "DNS:*.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertEqual(result.returncode, 0, result.stderr)

        result = run_installer("validate-certificate", cert, key, "foo.openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate does not cover foo.openvas.client.fr", result.stderr)

        no_dns_cert, no_dns_key = generate_self_signed_cert(self.tmp_path, "no-dns", "IP:127.0.0.1")
        result = run_installer("validate-certificate", no_dns_cert, no_dns_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate does not contain a DNS Subject Alternative Name", result.stderr)

        other_cert, other_key = generate_self_signed_cert(self.tmp_path, "other", "DNS:other.client.fr")
        result = run_installer("validate-certificate", other_cert, other_key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Certificate does not cover openvas.client.fr", result.stderr)

    def test_single_non_self_signed_certificate_warns_but_does_not_block(self):
        cert, key = generate_signed_leaf(self.tmp_path, "leaf", "DNS:openvas.client.fr")
        result = run_installer("validate-certificate", cert, key, "openvas.client.fr", env=make_env(self.tmp_path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[WARNING] The supplied certificate file contains only one certificate.", result.stdout)

    def test_copy_and_backup_permissions(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        old_cert, old_key = generate_self_signed_cert(self.tmp_path, "old", "DNS:openvas.client.fr")
        new_cert, new_key = generate_self_signed_cert(self.tmp_path / "source files", "new", "DNS:openvas.client.fr")
        certs = base / "certs"
        certs.mkdir()
        (certs / "server.cert.pem").write_bytes(old_cert.read_bytes())
        (certs / "server.key").write_bytes(old_key.read_bytes())

        env = make_env(self.tmp_path, base=base)
        self.assertEqual(run_installer("copy-certificate", new_cert, new_key, env=env).returncode, 0)
        self.assertEqual(stat.S_IMODE(certs.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((certs / "server.cert.pem").stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE((certs / "server.key").stat().st_mode), 0o600)

        docker = self.tmp_path / "docker"
        https = self.tmp_path / "https"
        write_mock_docker(docker)
        write_https_helper(https, new_cert)
        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=https)
        result = run_installer("install-custom", env=env, input_text=f"{new_cert}\n{new_key}\nopenvas.client.fr\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        backup = base / ".certificate-installer-backup"
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((backup / "server.key").stat().st_mode), 0o600)

    def test_compose_switches_are_idempotent_and_keep_both_visible(self):
        base = self.tmp_path / "openvas"
        compose = write_compose(base)
        env = make_env(self.tmp_path, base=base)
        original_gvm = "      ENABLE_NGINX_CONFIG: true\n      ENABLE_TLS_GENERATION: true\n"

        compose.chmod(0o640)
        self.assertEqual(run_installer("apply-custom", env=env).returncode, 0)
        self.assertEqual(stat.S_IMODE(compose.stat().st_mode), 0o640)
        self.assertEqual(run_installer("apply-custom", env=env).returncode, 0)
        self.assertEqual(stat.S_IMODE(compose.stat().st_mode), 0o640)
        content = compose.read_text()
        self.assertIn(CUSTOM_BLOCK.format(certs=base / "certs"), content)
        self.assertEqual(active_mounts(content), [f"- {base / 'certs'}:/etc/nginx/certs:ro"])
        self.assertEqual(content.count("Greenbone default self-signed certificate:"), 1)
        self.assertEqual(content.count("Easy-OpenVAS custom certificate:"), 1)
        self.assertIn(original_gvm, content)

        self.assertEqual(run_installer("apply-self-signed", env=env).returncode, 0)
        self.assertEqual(stat.S_IMODE(compose.stat().st_mode), 0o640)
        self.assertEqual(run_installer("apply-self-signed", env=env).returncode, 0)
        self.assertEqual(stat.S_IMODE(compose.stat().st_mode), 0o640)
        content = compose.read_text()
        self.assertIn(SELF_SIGNED_BLOCK.format(certs=base / "certs"), content)
        self.assertEqual(active_mounts(content), ["- nginx_certificates_vol:/etc/nginx/certs:ro"])
        self.assertIn(original_gvm, content)

    def test_compose_unknown_structure_or_two_active_mounts_are_rejected(self):
        base = self.tmp_path / "openvas"
        env = make_env(self.tmp_path, base=base)
        self.assertNotEqual(run_installer("validate-installation", env=env).returncode, 0)

        write_compose(base, COMPOSE.replace("  nginx:\n", "  web:\n"))
        self.assertNotEqual(run_installer("validate-installation", env=env).returncode, 0)

        two_active = COMPOSE.replace(
            "      - nginx_certificates_vol:/etc/nginx/certs:ro\n",
            f"      - nginx_certificates_vol:/etc/nginx/certs:ro\n      - {base / 'certs'}:/etc/nginx/certs:ro\n",
        )
        write_compose(base, two_active)
        result = run_installer("validate-installation", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported Greenbone Compose structure", result.stderr)

    def test_install_custom_uses_force_recreate_and_verifies_presented_fingerprint(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        docker = self.tmp_path / "docker"
        log = write_mock_docker(docker)
        cert1, key1 = generate_self_signed_cert(self.tmp_path, "custom1", "DNS:openvas.client.fr")
        cert2, key2 = generate_self_signed_cert(self.tmp_path, "custom2", "DNS:openvas.client.fr")
        https = self.tmp_path / "https"
        write_https_helper(https, cert1, cert2, cert2)

        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=https)
        result = run_installer("install-custom", env=env, input_text=f"{cert1}\n{key1}\nopenvas.client.fr\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run_installer("install-custom", env=env, input_text=f"{cert2}\n{key2}\nopenvas.client.fr\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((base / "certs" / "server.cert.pem").read_bytes(), cert2.read_bytes())
        docker_log = log.read_text()
        self.assertIn("up -d --force-recreate nginx", docker_log)
        self.assertNotIn("down -v", docker_log)
        self.assertNotIn("volume rm", docker_log)
        self.assertNotIn("system prune", docker_log)
        self.assertNotIn(key1.read_text(), result.stdout + result.stderr)

    def test_runtime_failures_and_rollback(self):
        for name, docker_kwargs, served_expected in [
            ("nginx-not-running", {"ps_output": ""}, True),
            ("https-unavailable", {}, False),
            ("fingerprint-mismatch", {}, True),
        ]:
            with self.subTest(name=name):
                base = self.tmp_path / name
                compose = write_compose(base)
                before = compose.read_text()
                docker = self.tmp_path / f"docker-{name}"
                write_mock_docker(docker, **docker_kwargs)
                cert, key = generate_self_signed_cert(self.tmp_path, f"cert-{name}", "DNS:openvas.client.fr")
                wrong, _ = generate_self_signed_cert(self.tmp_path, f"wrong-{name}", "DNS:openvas.client.fr")
                https = self.tmp_path / f"https-{name}"
                if served_expected:
                    write_https_helper(https, wrong if name == "fingerprint-mismatch" else cert)
                else:
                    https.write_text("#!/usr/bin/env bash\nexit 1\n")
                    https.chmod(0o755)
                env = make_env(self.tmp_path, base=base, docker=docker, https_helper=https)
                result = run_installer("install-custom", env=env, input_text=f"{cert}\n{key}\nopenvas.client.fr\ny\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(compose.read_text(), before)

    def test_https_available_after_retries(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        cert, key = generate_self_signed_cert(self.tmp_path, "custom", "DNS:openvas.client.fr")
        https = self.tmp_path / "https"
        attempts = self.tmp_path / "attempts"
        https.write_text(
            f"""#!/usr/bin/env bash
set -eu
count=0
if [[ -f "{attempts}" ]]; then count="$(cat "{attempts}")"; fi
count=$((count + 1))
printf '%s' "$count" > "{attempts}"
if (( count < 3 )); then exit 1; fi
cp "{cert}" "$EASY_OPENVAS_CERT_OUTPUT"
"""
        )
        https.chmod(0o755)
        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=https)
        result = run_installer("install-custom", env=env, input_text=f"{cert}\n{key}\nopenvas.client.fr\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(attempts.read_text(), "3")

    def test_docker_compose_config_failure_rolls_back_before_recreate(self):
        base = self.tmp_path / "openvas"
        compose = write_compose(base)
        before = compose.read_text()
        docker = self.tmp_path / "docker"
        log = write_mock_docker(docker, config_exit=1)
        cert, key = generate_self_signed_cert(self.tmp_path, "custom", "DNS:openvas.client.fr")
        https = self.tmp_path / "https"
        write_https_helper(https, cert)
        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=https)
        result = run_installer("install-custom", env=env, input_text=f"{cert}\n{key}\nopenvas.client.fr\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(compose.read_text(), before)
        self.assertNotIn("up -d --force-recreate nginx", log.read_text())


    def test_restore_self_signed_is_noop_when_already_active(self):
        base = self.tmp_path / "openvas"
        compose = write_compose(base)
        before = compose.read_text()
        docker = self.tmp_path / "docker"
        log = write_mock_docker(docker)
        env = make_env(self.tmp_path, base=base, docker=docker)
        result = run_installer("restore-self-signed", env=env, input_text="y\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[OK] Greenbone self-signed certificate is already active.", result.stdout)
        self.assertEqual(compose.read_text(), before)
        self.assertFalse(log.exists())

    def test_restore_self_signed_switches_mount_and_checks_certificate_changed(self):
        base = self.tmp_path / "openvas"
        compose = write_compose(base)
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        custom_cert, custom_key = generate_self_signed_cert(self.tmp_path, "custom", "DNS:openvas.client.fr")
        greenbone_cert, _ = generate_self_signed_cert(self.tmp_path, "greenbone", "DNS:localhost")
        install_https = self.tmp_path / "install-https"
        restore_https = self.tmp_path / "restore-https"
        write_https_helper(install_https, custom_cert)
        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=install_https)
        result = run_installer("install-custom", env=env, input_text=f"{custom_cert}\n{custom_key}\nopenvas.client.fr\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)

        restore_attempts = write_https_helper(restore_https, custom_cert, greenbone_cert)
        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=restore_https)
        result = run_installer("restore-self-signed", env=env, input_text="y\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(restore_attempts.read_text(), "2")
        docker_log = (self.tmp_path / "docker.log").read_text()
        self.assertIn("up -d --force-recreate nginx", docker_log)
        content = compose.read_text()
        self.assertEqual(active_mounts(content), ["- nginx_certificates_vol:/etc/nginx/certs:ro"])
        self.assertIn(f"# - {base / 'certs'}:/etc/nginx/certs:ro", content)

    def test_restore_self_signed_rolls_back_if_certificate_does_not_change(self):
        base = self.tmp_path / "openvas"
        compose = write_compose(base, COMPOSE.replace("      - nginx_certificates_vol:/etc/nginx/certs:ro\n", CUSTOM_BLOCK.format(certs=Path("/tmp/custom"))))
        before = compose.read_text()
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        cert, _ = generate_self_signed_cert(self.tmp_path, "same", "DNS:localhost")
        https = self.tmp_path / "https"
        write_https_helper(https, cert, cert)
        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=https)
        result = run_installer("restore-self-signed", env=env, input_text="y\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(compose.read_text(), before)

    def test_show_current_certificate_uses_presented_certificate(self):
        base = self.tmp_path / "openvas"
        write_compose(base)
        docker = self.tmp_path / "docker"
        write_mock_docker(docker)
        cert, _ = generate_self_signed_cert(self.tmp_path, "presented", "DNS:openvas.client.fr")
        https = self.tmp_path / "https"
        write_https_helper(https, cert)
        env = make_env(self.tmp_path, base=base, docker=docker, https_helper=https)
        result = run_installer("show-current", env=env, input_text="openvas.client.fr\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Current HTTPS certificate", result.stdout)
        self.assertIn("Mode................ Greenbone self-signed", result.stdout)
        self.assertIn("Status.............. [OK] Certificate valid", result.stdout)

    def test_safety_constraints_for_tests(self):
        self.assertFalse(Path("/opt/openvas/certs/server.key").exists())
        self.assertFalse(Path("/opt/openvas/certs/server.cert.pem").exists())
        self.assertIsNone(shutil.which("Openvas-installer.sh"))


if __name__ == "__main__":
    unittest.main()
