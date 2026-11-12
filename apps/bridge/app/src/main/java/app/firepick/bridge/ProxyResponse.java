package app.firepick.bridge;

import java.io.InputStream;
import java.util.Collections;
import java.util.Map;

public record ProxyResponse(
    int status,
    String contentType,
    InputStream body,
    Map<String, String> headers
) implements AutoCloseable {
    public ProxyResponse {
        headers = headers == null ? Collections.emptyMap() : Map.copyOf(headers);
    }

    @Override
    public void close() throws Exception {
        if (body != null) body.close();
    }
}
