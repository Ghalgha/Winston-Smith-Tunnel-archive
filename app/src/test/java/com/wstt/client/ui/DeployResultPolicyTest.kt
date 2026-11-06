package com.wstt.client.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeployResultPolicyTest {
    @Test
    fun exactMarkerAndZeroExitAreRequired() {
        assertTrue(isSuccessfulDeployResult(0, "done\nWSTT_DEPLOY_OK\n"))
        assertFalse(isSuccessfulDeployResult(1, "WSTT_DEPLOY_OK"))
        assertFalse(isSuccessfulDeployResult(0, "service is active"))
        assertFalse(isSuccessfulDeployResult(0, "prefix WSTT_DEPLOY_OK suffix"))
    }

    @Test
    fun deployRollbackExitIsExplainedWithoutPretendingSuccess() {
        assertEquals(
            "Новый релиз не прошёл проверку; предыдущая установка восстановлена",
            deployFailureMessage(30, "WSTT_DEPLOY_ROLLED_BACK\n"),
        )
        assertEquals(
            "Новый релиз не запустился, а автоматический rollback завершился с ошибкой — требуется проверка VPS",
            deployFailureMessage(31, "WSTT_DEPLOY_ROLLBACK_FAILED\n"),
        )
    }

    @Test
    fun rollbackKeepsConcreteServerReason() {
        assertEquals(
            "Новый релиз не прошёл проверку; предыдущая установка восстановлена " +
                "Причина: Проверенный candidate-бинарник исчез после остановки старого runtime",
            deployFailureMessage(
                30,
                "WSTT_DEPLOY_ERROR|cutover|Проверенный candidate-бинарник исчез после остановки старого runtime\n" +
                    "WSTT_DEPLOY_ROLLED_BACK\n",
            ),
        )
    }

    @Test
    fun preflightFailureExplainsThatLiveServiceWasNotStopped() {
        assertEquals(
            "Кандидат не прошёл предзапусковую проверку; работающий сервер не останавливался",
            deployFailureMessage(20, "probe failed"),
        )
    }

    @Test
    fun authFailureHasActionableMessage() {
        assertEquals(
            "SSH-аутентификация отклонена: проверьте логин, пароль и разрешение PasswordAuthentication на VPS",
            friendlyDeployError("Auth fail for methods 'publickey,password'"),
        )
    }

    @Test
    fun publicKeyFailureHasKeySpecificMessage() {
        assertTrue(
            friendlyDeployError("Auth fail (public key): rejected")
                .contains("authorized_keys"),
        )
    }

    @Test
    fun timeoutHasShortMessage() {
        assertEquals("Истекло время ожидания SSH/SFTP", friendlyDeployError("connect timeout"))
    }

    @Test
    fun exhaustedUploadHasNetworkSpecificMessage() {
        assertTrue(
            friendlyDeployError("SFTP/SCP upload failed for wstt: SFTP: channel closed")
                .contains("автоматического переподключения"),
        )
    }

    @Test
    fun serverSuccessLineBecomesCleanOkLog() {
        assertEquals(
            DeployOutputLine("wstt установлен", DeployOutputLevel.OK),
            parseDeployOutputLine("✓ wstt установлен"),
        )
    }

    @Test
    fun serverStepHasNoEmojiOrStatusSticker() {
        assertEquals(
            DeployOutputLine("Установка wstt...", DeployOutputLevel.LOG),
            parseDeployOutputLine("📦 Установка wstt..."),
        )
        assertEquals(
            DeployOutputLine("Проверка зависимостей", DeployOutputLevel.LOG),
            parseDeployOutputLine("[►] Проверка зависимостей"),
        )
    }

    @Test
    fun serverFailureBecomesErrorLog() {
        assertEquals(
            DeployOutputLine("Сервис wstt не запустился", DeployOutputLevel.ERR),
            parseDeployOutputLine("[✗] Сервис wstt не запустился"),
        )
    }

    @Test
    fun protocolAndDecorationLinesAreHidden() {
        assertNull(parseDeployOutputLine("WSTT_PROGRESS|0.6|Бинарник..."))
        assertNull(parseDeployOutputLine("WSTT_DEPLOY_ERROR|cutover|candidate disappeared"))
        assertNull(parseDeployOutputLine("════════════════════════════"))
        assertNull(parseDeployOutputLine("WSTT_DEPLOY_OK"))
        assertNull(parseDeployOutputLine("WSTT_DEPLOY_ROLLED_BACK"))
        assertNull(parseDeployOutputLine("WSTT_DEPLOY_ROLLBACK_FAILED"))
    }

    @Test
    fun dockerModeUsesRawEnvironmentValues() {
        assertEquals("docker", deployMode(true))
        assertEquals("systemd", deployMode(false))
        assertEquals("a b#$\"\\c  d", deployEnvironmentValue("a b#$\"\\c\r\nd", true))
        assertEquals("\"a b#$\\\"\\\\c  d\"", deployEnvironmentValue("a b#$\"\\c\r\nd", false))
    }

    @Test
    fun serverAssetMatchesTheRemoteVpsArchitecture() {
        assertEquals(ServerArchitecture.AMD64, serverArchitectureForMachine("x86_64\n"))
        assertEquals(ServerArchitecture.AMD64, serverArchitectureForMachine("amd64\n"))
        assertEquals(ServerArchitecture.ARM64, serverArchitectureForMachine("aarch64\n"))
        assertEquals(ServerArchitecture.ARM64, serverArchitectureForMachine("arm64\n"))
        assertEquals(ServerArchitecture.ARMV7, serverArchitectureForMachine("armv7l\n"))
        assertEquals(ServerArchitecture.ARMV7, serverArchitectureForMachine("armhf\n"))
    }

    @Test(expected = java.io.IOException::class)
    fun unsupportedRemoteVpsArchitectureStopsBeforeUpload() {
        serverArchitectureForMachine("riscv64\n")
    }

    @Test
    fun sshPasswordKeepsSpacesAndSpecialCharactersExactly() {
        assertEquals(
            "a !@#$%^&*()[]{};:,.?/\\|~+= b",
            sanitizeSshPassword("a !@#$%^&*()[]{};:,.?/\\|~+= b"),
        )
        assertEquals("pa ssword", sanitizeSshPassword("pa\n ss\rword"))
    }
}
