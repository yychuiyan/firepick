package app.firepick.bridge;

import android.content.Context;

import com.fongmi.quickjs.host.Host;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.Net;
import com.github.catvod.runtime.NodeRuntimeApi;
import com.github.catvod.runtime.PythonRuntime;
import com.github.catvod.utils.Local;
import com.github.catvod.utils.RuntimeModule;
import com.google.gson.JsonObject;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import dalvik.system.DexClassLoader;

public final class FongmiProviderRuntime implements ProviderRuntime {
    private static final long CALL_TIMEOUT = 60_000;
    private final Context context;
    private final Host host = new BridgeHost();
    private final Map<String, RuntimeSession> sessions = new ConcurrentHashMap<>();

    public FongmiProviderRuntime(Context context) {
        this.context = context.getApplicationContext();
    }

    @Override
    public JSONObject invoke(String sessionId, JSONObject session, JSONObject request)
        throws Exception {
        RuntimeSession runtime = sessions.computeIfAbsent(
            sessionId,
            id -> new RuntimeSession(session.optJSONObject("source"))
        );
        return runtime.invoke(request);
    }

    @Override
    public ProxyResponse proxy(
        String sessionId,
        JSONObject session,
        Map<String, String> parameters
    ) throws Exception {
        RuntimeSession runtime = sessions.computeIfAbsent(
            sessionId,
            id -> new RuntimeSession(session.optJSONObject("source"))
        );
        return runtime.proxy(parameters);
    }

    @Override
    public JSONArray capabilities() {
        JSONArray values = new JSONArray().put("quickJS").put("java");
        if (RuntimeModule.PYTHON.isInstalled()) values.put("python");
        if (RuntimeModule.NODEJS.isInstalled()) values.put("nodeJS");
        return values;
    }

    @Override
    public void closeSession(String sessionId) {
        RuntimeSession session = sessions.remove(sessionId);
        if (session != null) session.close();
    }

    @Override
    public void close() {
        List<RuntimeSession> active = new ArrayList<>(sessions.values());
        sessions.clear();
        active.forEach(RuntimeSession::close);
    }

    private final class RuntimeSession implements AutoCloseable {
        private final JSONObject source;
        private Spider spider;
        private NodeRuntimeApi.Client node;
        private boolean loaded;

        RuntimeSession(JSONObject source) {
            this.source = source == null ? new JSONObject() : source;
        }

        synchronized JSONObject invoke(JSONObject request) throws Exception {
            load();
            String method = request.getString("method");
            JSONArray args = request.optJSONArray("arguments");
            if (args == null) args = request.optJSONArray("args");
            if (args == null) args = new JSONArray();
            Object value = call(method, args);
            if (value == null) return new JSONObject();
            String text = String.valueOf(value).trim();
            if (text.isEmpty()) return new JSONObject();
            if ("liveContent".equals(method)) {
                return new JSONObject().put("content", text);
            }
            Object parsed = new JSONTokener(text).nextValue();
            if (parsed instanceof JSONObject object) return object;
            if (parsed instanceof JSONArray array) return new JSONObject().put("list", array);
            return new JSONObject().put("value", parsed);
        }

        synchronized ProxyResponse proxy(Map<String, String> parameters) throws Exception {
            load();
            Map<String, String> values = new HashMap<>(parameters);
            values.putIfAbsent("siteKey", source.optString("key", "firepick"));
            Object[] response = spider.proxy(values);
            if (response == null || response.length < 3) {
                throw new IllegalArgumentException("Proxy response requires status, MIME and body");
            }
            if (!(response[0] instanceof Number statusValue)) {
                throw new IllegalArgumentException("Proxy response status must be numeric");
            }
            int status = statusValue.intValue();
            if (status < 100 || status > 599
                || statusValue.doubleValue() != status) {
                throw new IllegalArgumentException("Proxy response status is invalid");
            }
            if (!(response[1] instanceof String contentType)) {
                throw new IllegalArgumentException("Proxy response MIME must be a string");
            }
            if (!(response[2] instanceof InputStream body)) {
                throw new IllegalArgumentException("Proxy response body must be a stream");
            }
            Map<String, String> headers = new HashMap<>();
            if (response.length > 3 && response[3] instanceof Map<?, ?> rawHeaders) {
                for (Map.Entry<?, ?> entry : rawHeaders.entrySet()) {
                    if (entry.getKey() != null && entry.getValue() != null) {
                        headers.put(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
                    }
                }
            }
            return new ProxyResponse(status, contentType, body, headers);
        }

        private void load() throws Exception {
            if (loaded) return;
            String api = source.optString("api").trim();
            if (api.isEmpty()) throw new IllegalArgumentException("Source API is missing");
            String jar = source.optString("jar", "").trim();
            String ext = extension(source.opt("ext"));
            DexClassLoader dex = loadDex(jar);

            if (api.endsWith(".js") || api.contains(".js?")) {
                com.fongmi.quickjs.crawler.Spider scripted =
                    new com.fongmi.quickjs.crawler.Spider(api, dex, host);
                scripted.siteKey = source.optString("key", "firepick");
                spider = scripted;
            } else if (api.startsWith("csp_")) {
                if (dex == null) throw new IllegalArgumentException("Java source requires a JAR");
                Spider java = newJavaSpider(api, dex);
                java.siteKey = source.optString("key", "firepick");
                java.net = new Net(host, java.siteKey);
                java.local = new Local(java.siteKey);
                spider = java;
            } else if (api.endsWith(".py")) {
                if (!RuntimeModule.PYTHON.isInstalled()) {
                    throw new UnsupportedOperationException("Python runtime module is not installed");
                }
                PythonRuntime python = RuntimeModule.PYTHON.entry(PythonRuntime.class);
                python.initialize();
                spider = python.spider(
                    api,
                    source.optString("key", "firepick"),
                    host,
                    host::getUserAgent
                );
            } else if (api.startsWith("node:")) {
                if (!RuntimeModule.NODEJS.isInstalled()) {
                    throw new UnsupportedOperationException("Node.js runtime module is not installed");
                }
                NodeRuntimeApi runtime = RuntimeModule.NODEJS.entry(NodeRuntimeApi.class);
                node = runtime.create(context, new NodeCallback());
                NodeRuntimeApi.LoadedConfig bundle = node.loadConfig(api.substring("node:".length()));
                node.accept(bundle);
                spider = node.spider(api);
            } else {
                throw new IllegalArgumentException("Unsupported Bridge source: " + api);
            }

            spider.init(context, ext);
            loaded = true;
        }

        private Spider newJavaSpider(String api, DexClassLoader dex) throws Exception {
            String name = api.substring("csp_".length());
            if (!name.matches("[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)*")) {
                throw new IllegalArgumentException("Invalid Java crawler class");
            }
            Class<?> type = dex.loadClass("com.github.catvod.spider." + name);
            return (Spider) type.getDeclaredConstructor().newInstance();
        }

        private Object call(String method, JSONArray args) throws Exception {
            return switch (method) {
                case "homeContent" -> spider.homeContent(booleanArgument(args, 0));
                case "homeVideoContent" -> spider.homeVideoContent();
                case "categoryContent" -> spider.categoryContent(
                    string(args.get(0)),
                    string(args.get(1)),
                    booleanArgument(args, 2),
                    stringMap(args.getJSONObject(3))
                );
                case "detailContent" -> spider.detailContent(strings(args.getJSONArray(0)));
                case "searchContent" -> {
                    String key = string(args.get(0));
                    boolean quick = booleanArgument(args, 1);
                    String page = args.length() > 2 ? string(args.get(2)) : "1";
                    yield page.equals("1")
                        ? spider.searchContent(key, quick)
                        : spider.searchContent(key, quick, page);
                }
                case "playerContent" -> spider.playerContent(
                    string(args.get(0)),
                    string(args.get(1)),
                    strings(args.getJSONArray(2))
                );
                case "liveContent" -> spider.liveContent(string(args.get(0)));
                case "action" -> spider.action(string(args.get(0)));
                default -> throw new IllegalArgumentException("Unsupported provider method: " + method);
            };
        }

        private DexClassLoader loadDex(String jar) throws Exception {
            if (jar.isEmpty()) return null;
            String[] segments = jar.split(";md5;", 2);
            String location = segments[0].trim();
            File file;
            if (location.startsWith("http://") || location.startsWith("https://")) {
                file = download(location);
            } else if (location.startsWith("file://")) {
                file = new File(URI.create(location));
            } else {
                file = new File(location);
            }
            if (!file.isFile()) throw new IllegalArgumentException("JAR not found: " + location);
            if (!file.setReadOnly()) {
                throw new SecurityException("Cannot make JAR read-only");
            }

            File dexDirectory = new File(context.getCodeCacheDir(), "spider-dex");
            if (!dexDirectory.isDirectory() && !dexDirectory.mkdirs()) {
                throw new IllegalStateException("Cannot create DEX cache");
            }
            DexClassLoader dex = new DexClassLoader(
                file.getAbsolutePath(),
                dexDirectory.getAbsolutePath(),
                context.getApplicationInfo().nativeLibraryDir,
                FongmiProviderRuntime.class.getClassLoader()
            );
            try {
                Class<?> init = dex.loadClass("com.github.catvod.spider.Init");
                init.getMethod("init", Context.class).invoke(null, context);
            } catch (ClassNotFoundException ignored) {
            }
            return dex;
        }

        private File download(String location) throws Exception {
            File directory = new File(context.getCacheDir(), "spider-jars");
            if (!directory.isDirectory() && !directory.mkdirs()) {
                throw new IllegalStateException("Cannot create JAR cache");
            }
            File target = new File(directory, digest(location) + ".jar");
            if (target.isFile() && target.length() > 0) return target;

            File temporary = File.createTempFile("spider-", ".jar", directory);
            HttpURLConnection connection = (HttpURLConnection) new URL(location).openConnection();
            connection.setConnectTimeout(15_000);
            connection.setReadTimeout(60_000);
            connection.setInstanceFollowRedirects(true);
            try (InputStream input = connection.getInputStream();
                 FileOutputStream output = new FileOutputStream(temporary)) {
                input.transferTo(output);
            } finally {
                connection.disconnect();
            }
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE
            );
            return target;
        }

        private String digest(String value) throws Exception {
            byte[] hash = MessageDigest.getInstance("SHA-256")
                .digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder text = new StringBuilder();
            for (byte item : hash) text.append(String.format("%02x", item));
            return text.toString();
        }

        private String extension(Object value) {
            if (value == null || value == JSONObject.NULL) return "";
            if (value instanceof String text) return text;
            return value.toString();
        }

        @Override
        public synchronized void close() {
            if (spider != null) {
                try {
                    spider.close();
                } catch (RuntimeException ignored) {
                }
                spider = null;
            }
            if (node != null) {
                try {
                    node.clear();
                } catch (RuntimeException ignored) {
                }
                node = null;
            }
            loaded = false;
        }
    }

    private static final class NodeCallback implements NodeRuntimeApi.Callback {
        @Override
        public String onMessage(String action, JsonObject options) {
            return switch (action) {
                case "getUserAgent" -> "{\"success\":true,\"code\":0,\"ua\":\"FirepickBridge/0.1\"}";
                case "getCookie" -> "{\"success\":true,\"code\":0,\"cookie\":\"\"}";
                case "setCookie", "toast", "danmuPush", "clearDanmu" ->
                    "{\"success\":true,\"code\":0}";
                default -> "{\"success\":false,\"code\":-1}";
            };
        }

        @Override
        public void onPlayInfo(String flag, String id) {
        }
    }

    private static boolean booleanArgument(JSONArray args, int index) throws Exception {
        Object value = args.get(index);
        if (!(value instanceof Boolean)) {
            throw new IllegalArgumentException("Argument requires a boolean: " + index);
        }
        return (Boolean) value;
    }

    private static String string(Object value) {
        if (!(value instanceof String)) throw new IllegalArgumentException("Argument requires a string");
        return (String) value;
    }

    private static List<String> strings(JSONArray array) throws Exception {
        List<String> output = new ArrayList<>();
        for (int i = 0; i < array.length(); i++) output.add(string(array.get(i)));
        return output;
    }

    private static HashMap<String, String> stringMap(JSONObject object) throws Exception {
        HashMap<String, String> output = new HashMap<>();
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            output.put(key, string(object.get(key)));
        }
        return output;
    }

    private static final class BridgeHost implements Host {
        @Override
        public long getCallTimeout() {
            return CALL_TIMEOUT;
        }

        @Override
        public String getUserAgent() {
            return "FirepickBridge/0.1";
        }

        @Override
        public String getCookie(String url) {
            return "";
        }

        @Override
        public boolean setCookie(String url, String cookie) {
            return false;
        }
    }
}
