package app.codexlauncher.capability.location

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.os.Build
import androidx.core.content.ContextCompat
import app.codexlauncher.diagnostics.AppLog
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private const val LOCATION_TIMEOUT_MILLIS = 10_000L
private const val GEOCODE_TIMEOUT_MILLIS = 3_000L

/** Fetches the device's current GPS location on behalf of the paired computer. */
object DeviceLocationAction {
    suspend fun fetchLocationJson(context: Context): String {
        return try {
            if (!hasLocationPermission(context)) {
                AppLog.info(
                    feature = "location",
                    message = "location request refused for missing permission",
                    fields = mapOf("decision" to "permission_denied"),
                )
                return failurePayload("permission_denied", "Location permission has not been granted.")
            }
            when (val outcome = withTimeoutOrNull(LOCATION_TIMEOUT_MILLIS) { awaitCurrentLocation(context) }) {
                null -> failurePayload("timeout", "Locating the device took too long.")
                is Location -> successPayload(context, outcome)
                else -> failurePayload("location_unavailable", "No location fix is currently available.")
            }
        } catch (error: Exception) {
            AppLog.error(
                feature = "location",
                message = "get_location attempt threw",
                error = error,
                fields = mapOf("decision" to "location_unavailable"),
            )
            failurePayload("location_unavailable", "The location attempt failed unexpectedly.")
        }
    }

    private fun hasLocationPermission(context: Context): Boolean {
        val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
        return fine == PackageManager.PERMISSION_GRANTED || coarse == PackageManager.PERMISSION_GRANTED
    }

    // withTimeoutOrNull returning null must mean "timed out". A resolved call with
    // no fix is a legitimate, distinct outcome, so it is represented as this
    // sentinel object rather than a bare Kotlin null, which would be indistinguishable
    // from a timeout to the caller.
    private object NoFix

    private suspend fun awaitCurrentLocation(context: Context): Any {
        val tokenSource = CancellationTokenSource()
        val task =
            LocationServices.getFusedLocationProviderClient(context)
                .getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, tokenSource.token)
        return suspendCancellableCoroutine { cont ->
            task.addOnSuccessListener { location -> cont.resume(location ?: NoFix) }
            task.addOnFailureListener { cont.resume(NoFix) }
            cont.invokeOnCancellation { tokenSource.cancel() }
        }
    }

    private suspend fun successPayload(context: Context, location: Location): String {
        val address = reverseGeocode(context, location.latitude, location.longitude)
        val json =
            buildJsonObject {
                put("latitude", location.latitude)
                put("longitude", location.longitude)
                put("accuracyMeters", if (location.hasAccuracy()) location.accuracy else 0f)
                put("timestampMillis", location.time)
                put("provider", location.provider?.takeIf { it.isNotBlank() } ?: "fused")
                if (address != null) put("address", address)
            }
        return json.toString()
    }

    private suspend fun reverseGeocode(context: Context, latitude: Double, longitude: Double): String? =
        try {
            val geocoder = Geocoder(context)
            val addresses =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    withTimeoutOrNull(GEOCODE_TIMEOUT_MILLIS) { awaitGeocode(geocoder, latitude, longitude) }
                } else {
                    // The pre-33 Geocoder call is synchronous and can block for
                    // seconds; this whole fetch runs on viewModelScope (Main), so
                    // it must hop to IO or it risks an ANR on API 31/32 devices.
                    @Suppress("DEPRECATION")
                    withContext(Dispatchers.IO) { geocoder.getFromLocation(latitude, longitude, 1) }
                }
            addresses?.firstOrNull()?.let(::addressLine)
        } catch (_: Exception) {
            null
        }

    // No Executor overload exists on this API level -- Geocoder.GeocodeListener
    // is delivered on the main thread by design, which is fine here since this
    // whole call is already timeout-guarded and never touches the UI itself.
    // onError must resume too: without it a geocode failure (no network, backend
    // error) never completes the continuation, so the caller waits out the whole
    // GEOCODE_TIMEOUT_MILLIS before falling back to a no-address result.
    private suspend fun awaitGeocode(geocoder: Geocoder, latitude: Double, longitude: Double): List<Address>? =
        suspendCancellableCoroutine { cont ->
            geocoder.getFromLocation(
                latitude,
                longitude,
                1,
                object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) {
                        if (cont.isActive) cont.resume(addresses)
                    }

                    override fun onError(errorMessage: String?) {
                        if (cont.isActive) cont.resume(null)
                    }
                },
            )
        }

    private fun addressLine(address: Address): String? = address.getAddressLine(0)

    private fun failurePayload(error: String, message: String): String =
        buildJsonObject {
            put("error", error)
            put("message", message)
        }.toString()
}
