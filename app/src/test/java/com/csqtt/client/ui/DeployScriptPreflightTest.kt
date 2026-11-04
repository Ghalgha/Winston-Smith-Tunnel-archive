package com.wstt.client.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeployScriptPreflightTest {
    private fun script(): String {
        val candidates = listOf(
            File("app/src/main/assets/deploy.sh"),
            File("src/main/assets/deploy.sh"),
        )
        return candidates.first(File::isFile).readText()
    }

    private fun deployOperations(): String {
        val candidates = listOf(
            File("app/src/main/java/com/csqtt/client/ui/DeployOperations.kt"),
            File("src/main/java/com/csqtt/client/ui/DeployOperations.kt"),
        )
        return candidates.first(File::isFile).readText()
    }

    @Test
    fun `installer owns only WSTT runtime paths`() {
        val deploy = script()
        assertTrue(deploy.contains("readonly WSTT_CONFIG_DIR=\"/etc/wstt\""))
        assertTrue(deploy.contains("readonly WSTT_IFACE=\"wstt1\""))
        assertTrue(deploy.contains("/usr/local/bin/wstt"))
        assertTrue(deploy.contains("wstt.service"))
        assertFalse(deploy.contains("/etc/csqtt"))
        assertFalse(deploy.contains("/usr/local/bin/csqtt"))
        assertFalse(deploy.contains("csqtt.service"))
    }

    @Test
    fun `installer has isolated network identity`() {
        val deploy = script()
        assertTrue(deploy.contains("10.67.68.0/24"))
        assertTrue(deploy.contains("WSTT_MANAGED"))
        assertTrue(deploy.contains("WSTT_TPROXY"))
        assertFalse(deploy.contains("CSQTT_MANAGED"))
        assertFalse(deploy.contains("CSQTT_TPROXY"))
        assertFalse(deploy.contains("WSTT_LOCAL_SOCKS"))
        assertTrue(deploy.contains("WSTT_PEER_PORT"))
        assertTrue(deploy.contains("WSTT_WEB_PORT"))
        assertFalse(deploy.contains("CSQTT_PEER_PORT"))
        assertFalse(deploy.contains("CSQTT_WEB_PORT"))
    }

    @Test
    fun `systemd and Docker resources are WSTT-specific`() {
        val deploy = script()
        assertTrue(deploy.contains("wstt.service"))
        assertTrue(deploy.contains("WSTT_DOCKER_CONTAINER=\"wstt\""))
        assertTrue(deploy.contains("WSTT_DOCKER_IMAGE=\"wstt:"))
        assertTrue(deploy.contains("--label com.wstt.managed=true"))
        assertFalse(deploy.contains("--security-opt seccomp=unconfined"))
        assertFalse(deploy.contains("--label com.csqtt.managed=true"))
    }

    @Test
    fun `deployment uploads use independent remote paths per invocation`() {
        val deploy = script()
        val client = deployOperations()
        assertTrue(deploy.contains("WSTT_UPLOAD_BINARY:-/tmp/.wstt-upload-server"))
        assertTrue(deploy.contains("WSTT_UPLOAD_ENV_FILE:-/tmp/.wstt-upload-web.env"))
        assertTrue(deploy.contains("WSTT_UPLOAD_OVERRIDES_FILE:-/tmp/.wstt-upload-overrides.json"))
        assertTrue(client.contains("UUID.randomUUID()"))
        assertTrue(client.contains("/tmp/.wstt-deploy-\$uploadToken.sh"))
        assertTrue(client.contains("/tmp/.wstt-upload-\$uploadToken-server"))
        assertTrue(client.contains("WSTT_UPLOAD_BINARY=\$remoteBinaryPath"))
        assertTrue(client.contains("WSTT_UPLOAD_ENV_FILE=\$remoteEnvironmentPath"))
        assertTrue(client.contains("WSTT_UPLOAD_OVERRIDES_FILE=\$remoteOverridesPath"))
    }

    @Test
    fun `Certbot issuance and renewal share an HTTP-01 lock`() {
        val deploy = script()
        assertTrue(deploy.contains("WSTT_LE_HTTP01_LOCK=\"/run/lock/acme-http01.lock\""))
        assertTrue(deploy.contains("flock -w 120 9"))
        assertTrue(deploy.contains("timeout 30 systemctl stop \"\$WSTT_LE_SERVICE\""))
        assertTrue(deploy.contains("systemctl kill --kill-who=all --signal=SIGKILL \"\$WSTT_LE_SERVICE\""))
        assertTrue(deploy.contains("HTTP01_LOCK_FILE=\"/run/lock/acme-http01.lock\""))
        assertTrue(deploy.contains("WSTT_LE_CONFIG_DIR=\"\${WSTT_CONFIG_DIR}/letsencrypt\""))
        assertTrue(deploy.contains("--config-dir \"\$WSTT_LE_CONFIG_DIR\" --work-dir \"\$WSTT_LE_WORK_DIR\" --logs-dir \"\$WSTT_LE_LOGS_DIR\""))
        assertTrue(deploy.contains("LE_CONFIG_DIR=\"\${CONFIG_DIR}/letsencrypt\""))
        assertTrue(deploy.contains("--config-dir \"\$LE_CONFIG_DIR\" --work-dir \"\$LE_WORK_DIR\" --logs-dir \"\$LE_LOGS_DIR\""))
        assertTrue(deploy.contains("source_dir=\"\${LE_CONFIG_DIR}/live/\${cert_name}\""))
        assertTrue(deploy.contains("|letsencrypt|runtime-archive) continue ;;"))
        assertTrue(deploy.contains("exec 9>\"\$HTTP01_LOCK_FILE\""))
    }

    @Test
    fun `host-wide network security settings remain untouched`() {
        val deploy = script()
        assertFalse(deploy.contains("chmod 666 /dev/net/tun"))
        assertFalse(deploy.contains("net.ipv4.conf.all.rp_filter"))
        assertFalse(deploy.contains("net.ipv4.conf.default.rp_filter"))
        assertFalse(deploy.contains("net.ipv6.conf.default.disable_ipv6"))
        assertFalse(deploy.contains("WAN_IFACE/rp_filter"))
        assertTrue(deploy.contains("WAN_IFACE/accept_ra"))
        assertTrue(deploy.contains("net.ipv6.conf.\${iface}.accept_ra=2"))
        assertFalse(deploy.contains("net.ipv4.conf.\${iface}.rp_filter=2"))
        assertFalse(deploy.contains("mitigations=off"))
    }

    @Test
    fun `WSTT network policy is scoped to its own interface`() {
        val deploy = script()
        assertTrue(deploy.contains("wstt1"))
        assertTrue(deploy.contains("WSTT_MANAGED"))
        assertTrue(deploy.contains("delete_marked_rules"))
        assertTrue(deploy.contains("cleanup_wstt_policy_routes()"))
        assertTrue(deploy.contains("priority 1067 table 1067"))
        assertTrue(deploy.contains("priority 30002 table 30002"))
        assertTrue(deploy.contains("ip6tables"))
        assertTrue(deploy.contains("iptables -w"))
    }

    @Test
    fun `installer validates ports and preflights before activation`() {
        val deploy = script()
        val installBranch = deploy.substringAfter("install|--install|-i)")
        assertTrue(deploy.contains("validate_distinct_network_ports()"))
        assertTrue(deploy.contains("assert_wstt_ports_preflight"))
        assertTrue(deploy.contains("listener_line_is_wstt_owned"))
        assertTrue(deploy.contains("assert_web_port_is_available"))
        assertTrue(deploy.contains("ss -H -ltnp \"sport = :\${WEB_PORT}\""))
        assertTrue(deploy.contains("[ \"\$WEB_PORT\" != \"\$LE_HTTP_PORT\" ]"))
        assertTrue(deploy.contains("[ \"\$SSH_PORT\" != \"\$LE_HTTP_PORT\" ]"))
        assertTrue(deploy.contains("run_platform_preflight()"))
        assertTrue(installBranch.indexOf("prepare_uploaded_release") >= 0)
        assertTrue(installBranch.indexOf("run_platform_preflight") < installBranch.indexOf("wstt_cleanup"))
        assertTrue(installBranch.indexOf("assert_wstt_ports_preflight") < installBranch.indexOf("wstt_cleanup"))
        assertTrue(installBranch.indexOf("run_platform_preflight") < installBranch.indexOf("setup_sysctl"))
        assertTrue(installBranch.indexOf("wstt_cleanup") < installBranch.indexOf("setup_sysctl"))
        assertTrue(installBranch.indexOf("run_platform_preflight") < installBranch.indexOf("setup_wstt_binary"))
        assertTrue(installBranch.indexOf("setup_nat_and_firewall") < installBranch.indexOf("setup_wstt_binary"))
        assertTrue(installBranch.indexOf("wstt_cleanup") < installBranch.indexOf("setup_wstt_binary"))
    }

    @Test
    fun `TUN permissions are not made world writable`() {
        val deploy = script()
        assertFalse(Regex("chmod\\s+666\\s+/dev/net/tun").containsMatchIn(deploy))
        assertTrue(deploy.contains("ensure_tun_device"))
        assertTrue(deploy.contains("probe_tun_support"))
    }

    @Test
    fun `Android app identity differs from WSTT`() {
        val candidates = listOf(File("app/build.gradle.kts"), File("build.gradle.kts"))
        val gradle = candidates.first(File::isFile).readText()
        assertTrue(gradle.contains("applicationId = \"com.wstunnel.client\""))
    }
    @Test
    fun `uninstall reports remote execution failures`() {
        val client = deployOperations()
        assertTrue(client.contains("val uninstallResult = sshClient.execResult("))
        assertTrue(client.contains("if (uninstallResult.exitStatus != 0)"))
        assertTrue(client.contains("Удаление WSTT завершилось с кодом"))
    }

}
