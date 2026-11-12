package app.firepick.bridge;

import org.json.JSONObject;

/**
 * Foundation implementation until the pinned FongMi modules are wired into the
 * Bridge module. The protocol surface is live; provider calls fail explicitly
 * instead of silently returning empty data.
 */
public final class UnavailableProviderRuntime implements ProviderRuntime {
    @Override
    public JSONObject invoke(String sessionId, JSONObject session, JSONObject request) throws Exception {
        throw new UnsupportedOperationException(
            "FongMi provider runtime is not linked in this foundation build"
        );
    }
}

