package com.androidbridge.connection

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.util.UUID

class PairingStore(private val context: Context) {

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun hasPairedDevice(): Boolean {
        return prefs.contains(KEY_PAIRED_MAC_ID)
    }

    fun getPairedDeviceId(): String? {
        return prefs.getString(KEY_PAIRED_MAC_ID, null)
    }

    fun getDeviceId(): String {
        var id = prefs.getString(KEY_DEVICE_ID, null)
        if (id == null) {
            id = UUID.randomUUID().toString()
            prefs.edit().putString(KEY_DEVICE_ID, id).apply()
        }
        return id
    }

    fun savePairedMac(macDeviceId: String, certFingerprint: String) {
        prefs.edit()
            .putString(KEY_PAIRED_MAC_ID, macDeviceId)
            .putString(KEY_PAIRED_CERT_FINGERPRINT, certFingerprint)
            .apply()
        Log.i(TAG, "Paired with Mac: ${macDeviceId.take(8)}...")
    }

    fun getPairedCertFingerprint(): String? {
        return prefs.getString(KEY_PAIRED_CERT_FINGERPRINT, null)
    }

    fun generateKeyPair() {
        try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)

            if (keyStore.containsAlias(KEYSTORE_ALIAS)) {
                Log.i(TAG, "Key pair already exists")
                return
            }

            val spec = KeyGenParameterSpec.Builder(
                KEYSTORE_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setKeySize(2048)
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                .build()

            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore"
            )
            generator.initialize(spec)
            generator.generateKeyPair()

            Log.i(TAG, "Generated RSA key pair in AndroidKeyStore")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to generate key pair", e)
        }
    }

    fun getPublicKeyBytes(): ByteArray? {
        return try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            keyStore.getCertificate(KEYSTORE_ALIAS)?.publicKey?.encoded
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get public key", e)
            null
        }
    }

    fun derivePairingPort(): Int {
        val id = getDeviceId()
        val hash = id.hashCode() and 0x7FFFFFFF
        return 10000 + (hash % 50000)
    }

    fun clearPairing() {
        prefs.edit()
            .remove(KEY_PAIRED_MAC_ID)
            .remove(KEY_PAIRED_CERT_FINGERPRINT)
            .apply()
    }

    companion object {
        private const val TAG = "PairingStore"
        private const val PREFS_NAME = "androidbridge_pairing"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_PAIRED_MAC_ID = "paired_mac_id"
        private const val KEY_PAIRED_CERT_FINGERPRINT = "paired_cert_fingerprint"
        private const val KEYSTORE_ALIAS = "androidbridge_rsa"
    }
}
