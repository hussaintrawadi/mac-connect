package com.androidbridge.connection

sealed class ConnectionState {
    data object Disconnected : ConnectionState()
    data object Searching : ConnectionState()
    data object Connecting : ConnectionState()
    data class Connected(val deviceName: String) : ConnectionState()
    data object Reconnecting : ConnectionState()

    val isConnected: Boolean get() = this is Connected
}
