package com.wstt.client

internal fun shouldConfirmTcpTransport(
    currentTransport: String,
    requestedTransport: String,
    warningAcknowledged: Boolean,
): Boolean =
    !warningAcknowledged &&
        currentTransport != WsttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS &&
        requestedTransport == WsttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS
