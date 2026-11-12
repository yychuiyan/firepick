package app.firepick.bridge;

import org.json.JSONObject;
import org.json.JSONArray;

import java.util.Map;

public interface ProviderRuntime {
    JSONObject invoke(String sessionId, JSONObject session, JSONObject request) throws Exception;

    default ProxyResponse proxy(String sessionId, JSONObject session, Map<String, String> parameters)
        throws Exception {
        throw new UnsupportedOperationException("Provider proxy is not available");
    }

    default JSONArray capabilities() {
        return new JSONArray();
    }

    default void closeSession(String sessionId) {
    }

    default void close() {
    }
}

