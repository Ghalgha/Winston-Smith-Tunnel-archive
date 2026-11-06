package com.wstt.client

import org.junit.Assert.assertEquals
import org.junit.Test

class TurnTransportPolicyTest {
    @Test
    fun tcpWarningAppearsOnlyWhenEnteringTcpWithoutAcknowledgement() {
        assertEquals(
            true,
            shouldConfirmTcpTransport(
                currentTransport = WsttConstants.Tunnel.DEFAULT_TURN_TRANSPORT,
                requestedTransport = WsttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS,
                warningAcknowledged = false,
            ),
        )
        assertEquals(
            false,
            shouldConfirmTcpTransport(
                currentTransport = WsttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS,
                requestedTransport = WsttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS,
                warningAcknowledged = false,
            ),
        )
        assertEquals(
            false,
            shouldConfirmTcpTransport(
                currentTransport = WsttConstants.Tunnel.DEFAULT_TURN_TRANSPORT,
                requestedTransport = WsttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS,
                warningAcknowledged = true,
            ),
        )
    }
}
