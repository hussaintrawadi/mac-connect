package com.androidbridge.connection

import java.util.concurrent.ConcurrentHashMap

class RateLimiter(
    private val maxFailures: Int = 5,
    private val blockDurationMs: Long = 10 * 60 * 1000
) {
    private data class Entry(var failures: Int = 0, var blockedUntil: Long = 0)

    private val entries = ConcurrentHashMap<String, Entry>()

    fun isBlocked(address: String): Boolean {
        val entry = entries[address] ?: return false
        if (entry.blockedUntil > System.currentTimeMillis()) return true
        if (entry.blockedUntil != 0L) {
            entries.remove(address)
        }
        return false
    }

    fun recordFailure(address: String) {
        val entry = entries.getOrPut(address) { Entry() }
        entry.failures++
        if (entry.failures >= maxFailures) {
            entry.blockedUntil = System.currentTimeMillis() + blockDurationMs
        }
    }

    fun recordSuccess(address: String) {
        entries.remove(address)
    }
}
