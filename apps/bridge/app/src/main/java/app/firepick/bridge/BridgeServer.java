package app.firepick.bridge;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import javax.net.ssl.SSLServerSocket;

public final class BridgeServer implements AutoCloseable {
    private static final int DEFAULT_PORT = 9443;
    private final PairingStore pairing;
    private final ProviderRuntime runtime;
    private final TlsMaterial tls;
    private final Map<String, JSONObject> sessions = new ConcurrentHashMap<>();
    private final Map<String, Long> sessionExpirations = new ConcurrentHashMap<>();
    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final AtomicBoolean running = new AtomicBoolean();
    private volatile SSLServerSocket serverSocket;
    private volatile String configDigest;
    private volatile byte[] config;

    public BridgeServer(File filesDir, PairingStore pairing, ProviderRuntime runtime) throws Exception {
        this.pairing = pairing;
        this.runtime = runtime;
        this.tls = TlsMaterial.loadOrCreate(filesDir);
    }

    public synchronized void start() throws Exception {
        if (running.get()) return;
        serverSocket = (SSLServerSocket) tls.context.getServerSocketFactory()
            .createServerSocket(DEFAULT_PORT);
        running.set(true);
        executor.execute(this::acceptLoop);
    }

    public String address() {
        SSLServerSocket socket = serverSocket;
        return socket == null ? "" : "https://" + localAddress() + ":" + socket.getLocalPort();
    }

    public String fingerprint() {
        return tls.fingerprint;
    }

    public String pairingURI() throws Exception {
        return "firepick://pair?id=" + UUID.randomUUID()
            + "&name=Firepick%20Bridge"
            + "&url=" + java.net.URLEncoder.encode(address(), StandardCharsets.UTF_8.name())
            + "&pin=" + fingerprint()
            + "&code=" + pairing.currentCode();
    }

    public void resetPairings() {
        pairing.resetTokens();
        for (String session : sessions.keySet()) runtime.closeSession(session);
        sessions.clear();
        sessionExpirations.clear();
    }

    public String pairingCode() {
        return pairing.currentCode();
    }

    private void acceptLoop() {
        while (running.get()) {
            try {
                Socket socket = serverSocket.accept();
                executor.execute(() -> handle(socket));
            } catch (Exception error) {
                if (running.get()) error.printStackTrace();
            }
        }
    }

    private void handle(Socket socket) {
        try (socket) {
            Request request = Request.read(socket.getInputStream());
            Response response = route(request);
            write(socket.getOutputStream(), response, request.method.equals("HEAD"));
        } catch (Exception error) {
            try {
                write(
                    socket.getOutputStream(),
                    Response.json(500, errorEnvelope("bad_request", error.getMessage())),
                    false
                );
            } catch (Exception ignored) {
            }
        }
    }

    private Response route(Request request) throws Exception {
        if (request.path.equals("/v1/health") && request.method.equals("GET")) {
            JSONObject body = new JSONObject()
                .put("protocolVersion", 1)
                .put("bridgeVersion", "0.1.0")
                .put("configDigest", configDigest == null ? JSONObject.NULL : configDigest)
                .put("runtimes", runtime.capabilities())
                .put("available", running.get());
            return Response.json(200, body);
        }

        if (request.path.equals("/v1/pair") && request.method.equals("POST")) {
            try {
                JSONObject body = new JSONObject(request.bodyText());
                String token = pairing.claim(body.getString("code"));
                return Response.json(200, new JSONObject().put("token", token));
            } catch (SecurityException error) {
                return Response.json(401, errorEnvelope("pairing_code_invalid", error.getMessage()));
            } catch (IllegalStateException error) {
                return Response.json(409, errorEnvelope("too_many_devices", error.getMessage()));
            } catch (Exception error) {
                System.err.println(
                    "Pairing request rejected: body=" + request.body.length
                        + " transfer=" + request.headers.get("transfer-encoding")
                        + " length=" + request.headers.get("content-length")
                );
                error.printStackTrace();
                return Response.json(400, errorEnvelope("bad_request", error.getMessage()));
            }
        }

        if (!pairing.authorize(request.bearerToken())) {
            return Response.json(401, errorEnvelope("unauthorized", "Pairing required"));
        }

        if (request.path.startsWith("/v1/configs/") && request.method.equals("PUT")) {
            configDigest = request.path.substring("/v1/configs/".length());
            config = request.body();
            if (!app.firepick.bridge.ConfigurationDigest.sha256(config).equals(configDigest)) {
                return Response.json(400, errorEnvelope("bad_request", "Config digest mismatch"));
            }
            return new Response(204, "application/json", new byte[0]);
        }

        if (request.path.equals("/v1/sessions") && request.method.equals("POST")) {
            try {
                pruneSessions();
                JSONObject body = new JSONObject(request.bodyText());
                if (!body.getString("configDigest").equals(configDigest)) {
                    return Response.json(422, errorEnvelope("config_missing", "Upload config first"));
                }
                String id = UUID.randomUUID().toString();
                sessions.put(id, body);
                sessionExpirations.put(
                    id,
                    java.time.Instant.now().plusSeconds(900).toEpochMilli()
                );
                return Response.json(200, new JSONObject()
                    .put("sessionId", id)
                    .put("expiresAt", java.time.Instant.now().plusSeconds(900).toString()));
            } catch (Exception error) {
                return Response.json(400, errorEnvelope("bad_request", error.getMessage()));
            }
        }

        String prefix = "/v1/sessions/";
        if (request.path.startsWith(prefix) && request.method.equals("DELETE")) {
            String id = request.path.substring(prefix.length());
            sessions.remove(id);
            sessionExpirations.remove(id);
            runtime.closeSession(id);
            return new Response(204, "application/json", new byte[0]);
        }

        String proxySuffix = "/proxy";
        if (request.path.startsWith(prefix) && request.path.endsWith(proxySuffix)
            && (request.method.equals("GET") || request.method.equals("HEAD"))) {
            String id = request.path.substring(prefix.length(), request.path.length() - proxySuffix.length());
            JSONObject session = activeSession(id);
            if (session == null) return Response.json(404, errorEnvelope("session_missing", "Session expired"));
            Map<String, String> parameters = new HashMap<>(request.queryParameters());
            request.headers.forEach((name, value) -> {
                if (!name.equals("authorization") && !name.equals("host")) {
                    parameters.putIfAbsent(name, value);
                }
            });
            try {
                ProxyResponse proxy = runtime.proxy(id, session, parameters);
                Map<String, String> headers = new HashMap<>(proxy.headers());
                long contentLength = -1;
                String length = headers.remove("Content-Length");
                if (length == null) length = headers.remove("content-length");
                if (length != null) {
                    try {
                        contentLength = Long.parseLong(length);
                    } catch (NumberFormatException ignored) {
                    }
                }
                headers.remove("Transfer-Encoding");
                headers.remove("transfer-encoding");
                headers.remove("Content-Type");
                headers.remove("content-type");
                headers.remove("Connection");
                headers.remove("connection");
                return new Response(
                    proxy.status(),
                    proxy.contentType(),
                    null,
                    proxy.body(),
                    contentLength,
                    headers
                );
            } catch (UnsupportedOperationException error) {
                return Response.json(501, errorEnvelope("runtime_missing", error.getMessage()));
            } catch (Exception error) {
                error.printStackTrace();
                return Response.json(502, errorEnvelope("proxy_failed", error.getMessage()));
            }
        }

        String invokeSuffix = "/invoke";
        if (request.path.startsWith(prefix) && request.path.endsWith(invokeSuffix)
            && request.method.equals("POST")) {
            String id = request.path.substring(prefix.length(), request.path.length() - invokeSuffix.length());
            JSONObject session = activeSession(id);
            if (session == null) return Response.json(404, errorEnvelope("session_missing", "Session expired"));
            try {
                return Response.json(200, runtime.invoke(id, session, new JSONObject(request.bodyText())));
            } catch (UnsupportedOperationException error) {
                return Response.json(501, errorEnvelope("runtime_missing", error.getMessage()));
            } catch (Exception error) {
                error.printStackTrace();
                return Response.json(500, errorEnvelope("provider_failed", error.getMessage()));
            }
        }

        return Response.json(404, errorEnvelope("unsupported", "Unknown endpoint"));
    }

    private JSONObject activeSession(String id) {
        Long expiresAt = sessionExpirations.get(id);
        if (expiresAt == null || expiresAt < System.currentTimeMillis()) {
            sessions.remove(id);
            sessionExpirations.remove(id);
            runtime.closeSession(id);
            return null;
        }
        return sessions.get(id);
    }

    private String localAddress() {
        try {
            var interfaces = java.net.NetworkInterface.getNetworkInterfaces();
            while (interfaces.hasMoreElements()) {
                var network = interfaces.nextElement();
                if (!network.isUp() || network.isLoopback()) continue;
                var addresses = network.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    var address = addresses.nextElement();
                    if (address instanceof java.net.Inet4Address
                        && address.isSiteLocalAddress()) {
                        return address.getHostAddress();
                    }
                }
            }
            return InetAddress.getLocalHost().getHostAddress();
        } catch (Exception error) {
            return "127.0.0.1";
        }
    }

    private static JSONObject errorEnvelope(String code, String message) throws Exception {
        return new JSONObject().put("code", code).put("message", message == null ? code : message);
    }

    private static void write(OutputStream output, Response response, boolean headOnly) throws Exception {
        try (response) {
            StringBuilder head = new StringBuilder()
                .append("HTTP/1.1 ").append(response.status).append(' ')
                .append(reason(response.status)).append("\r\n")
                .append("Content-Type: ").append(response.contentType).append("\r\n");
            response.headers.forEach((name, value) ->
                head.append(name).append(": ").append(value).append("\r\n")
            );
            boolean chunked = response.stream != null && response.contentLength < 0;
            if (chunked) {
                head.append("Transfer-Encoding: chunked\r\n");
            } else {
                long length = response.stream == null ? response.body.length : response.contentLength;
                head.append("Content-Length: ").append(length).append("\r\n");
            }
            head.append("Connection: close\r\n\r\n");
            output.write(head.toString().getBytes(StandardCharsets.UTF_8));
            if (!headOnly && response.stream != null) {
                if (chunked) {
                    byte[] buffer = new byte[64 * 1024];
                    int count;
                    while ((count = response.stream.read(buffer)) >= 0) {
                        if (count == 0) continue;
                        output.write(Integer.toHexString(count).getBytes(StandardCharsets.US_ASCII));
                        output.write("\r\n".getBytes(StandardCharsets.US_ASCII));
                        output.write(buffer, 0, count);
                        output.write("\r\n".getBytes(StandardCharsets.US_ASCII));
                        output.flush();
                    }
                    output.write("0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                } else {
                    response.stream.transferTo(output);
                }
            } else if (!headOnly) {
                output.write(response.body);
            }
            output.flush();
        }
    }

    private static String reason(int status) {
        return switch (status) {
            case 200 -> "OK";
            case 204 -> "No Content";
            case 206 -> "Partial Content";
            case 400 -> "Bad Request";
            case 401 -> "Unauthorized";
            case 404 -> "Not Found";
            case 408 -> "Request Timeout";
            case 409 -> "Conflict";
            case 422 -> "Unprocessable Content";
            case 500 -> "Internal Server Error";
            case 501 -> "Not Implemented";
            case 502 -> "Bad Gateway";
            default -> "Error";
        };
    }

    @Override
    public synchronized void close() {
        running.set(false);
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (Exception ignored) {
            }
        }
        executor.shutdownNow();
        sessions.clear();
        sessionExpirations.clear();
        runtime.close();
    }

    private void pruneSessions() {
        long now = System.currentTimeMillis();
        for (Map.Entry<String, Long> entry : sessionExpirations.entrySet()) {
            if (entry.getValue() >= now) continue;
            String id = entry.getKey();
            sessionExpirations.remove(id, entry.getValue());
            sessions.remove(id);
            runtime.closeSession(id);
        }
    }

    private static final class Response implements AutoCloseable {
        final int status;
        final String contentType;
        final byte[] body;
        final InputStream stream;
        final long contentLength;
        final Map<String, String> headers;

        Response(int status, String contentType, byte[] body) {
            this(status, contentType, body, null, body.length, Map.of());
        }

        Response(
            int status,
            String contentType,
            byte[] body,
            InputStream stream,
            long contentLength,
            Map<String, String> headers
        ) {
            this.status = status;
            this.contentType = contentType;
            this.body = body;
            this.stream = stream;
            this.contentLength = contentLength;
            this.headers = headers;
        }

        static Response json(int status, JSONObject body) {
            return new Response(status, "application/json; charset=utf-8",
                body.toString().getBytes(StandardCharsets.UTF_8));
        }

        @Override
        public void close() throws Exception {
            if (stream != null) stream.close();
        }
    }

    private record Request(
        String method,
        String path,
        String query,
        Map<String, String> headers,
        byte[] body
    ) {
        static Request read(InputStream rawInput) throws Exception {
            BufferedInputStream input = new BufferedInputStream(rawInput);
            String requestLine = line(input);
            if (requestLine == null || requestLine.isBlank()) throw new IllegalArgumentException("Empty request");
            String[] parts = requestLine.split(" ", 3);
            if (parts.length < 3) throw new IllegalArgumentException("Invalid request line");
            Map<String, String> headers = new LinkedHashMap<>();
            String header;
            while ((header = line(input)) != null && !header.isEmpty()) {
                int colon = header.indexOf(':');
                if (colon > 0) headers.put(header.substring(0, colon).trim().toLowerCase(), header.substring(colon + 1).trim());
            }
            byte[] body = headers.getOrDefault("transfer-encoding", "")
                .toLowerCase()
                .contains("chunked")
                ? readChunked(input)
                : input.readNBytes(Integer.parseInt(headers.getOrDefault("content-length", "0")));
            String[] target = parts[1].split("\\?", 2);
            return new Request(
                parts[0],
                target[0],
                target.length > 1 ? target[1] : "",
                headers,
                body
            );
        }

        private static byte[] readChunked(InputStream input) throws Exception {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            while (true) {
                String header = line(input);
                if (header == null) throw new IllegalArgumentException("Incomplete chunked body");
                int extension = header.indexOf(';');
                String sizeText = (extension >= 0 ? header.substring(0, extension) : header).trim();
                int size = Integer.parseInt(sizeText, 16);
                if (size == 0) {
                    while (true) {
                        String trailer = line(input);
                        if (trailer == null || trailer.isEmpty()) break;
                    }
                    return output.toByteArray();
                }
                byte[] chunk = input.readNBytes(size);
                if (chunk.length != size) throw new IllegalArgumentException("Incomplete chunk");
                output.write(chunk);
                String terminator = line(input);
                if (terminator == null || !terminator.isEmpty()) {
                    throw new IllegalArgumentException("Invalid chunk terminator");
                }
            }
        }

        String bodyText() throws Exception {
            return new String(body, StandardCharsets.UTF_8);
        }

        String bearerToken() {
            String auth = headers.get("authorization");
            if (auth == null || !auth.startsWith("Bearer ")) return null;
            return auth.substring(7);
        }

        Map<String, String> queryParameters() {
            Map<String, String> output = new HashMap<>();
            if (query.isEmpty()) return output;
            for (String pair : query.split("&")) {
                if (pair.isEmpty()) continue;
                String[] parts = pair.split("=", 2);
                String name = URLDecoder.decode(parts[0], StandardCharsets.UTF_8);
                String value = parts.length > 1
                    ? URLDecoder.decode(parts[1], StandardCharsets.UTF_8)
                    : "";
                output.put(name, value);
            }
            return output;
        }

        private static String line(InputStream input) throws Exception {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            int previous = -1;
            while (true) {
                int current = input.read();
                if (current < 0) return bytes.size() == 0 ? null : bytes.toString(StandardCharsets.UTF_8);
                if (previous == '\r' && current == '\n') {
                    byte[] value = bytes.toByteArray();
                    return new String(value, 0, Math.max(0, value.length - 1), StandardCharsets.UTF_8);
                }
                bytes.write(current);
                previous = current;
            }
        }
    }
}

