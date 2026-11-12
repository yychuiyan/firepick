package app.firepick.bridge;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.provider.Settings;

import androidx.core.content.FileProvider;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

public final class RuntimeInstaller {
    private static final ExecutorService executor = Executors.newSingleThreadExecutor();

    private RuntimeInstaller() {
    }

    public static boolean isInstalled(Activity activity, JSONObject module) {
        try {
            activity.getPackageManager().getPackageInfo(
                module.getString("packageName"),
                0
            );
            return true;
        } catch (PackageManager.NameNotFoundException error) {
            return false;
        } catch (Exception error) {
            return false;
        }
    }

    public static void install(
        Activity activity,
        JSONObject module,
        Consumer<String> status
    ) {
        if (isInstalled(activity, module)) {
            status.accept("已安装");
            return;
        }
        if (!activity.getPackageManager().canRequestPackageInstalls()) {
            Intent settings = new Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + activity.getPackageName())
            );
            activity.startActivity(settings);
            status.accept("请先允许安装未知来源应用，然后再次点击安装");
            return;
        }
        status.accept("正在下载…");
        executor.execute(() -> {
            try {
                File file = download(activity, module);
                activity.runOnUiThread(() -> {
                    Uri uri = FileProvider.getUriForFile(
                        activity,
                        activity.getPackageName() + ".files",
                        file
                    );
                    Intent install = new Intent(Intent.ACTION_VIEW)
                        .setDataAndType(
                            uri,
                            "application/vnd.android.package-archive"
                        )
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    activity.startActivity(install);
                    status.accept("请确认系统安装");
                });
            } catch (Exception error) {
                activity.runOnUiThread(
                    () -> status.accept("安装失败：" + error.getMessage())
                );
            }
        });
    }

    private static File download(Activity activity, JSONObject module) throws Exception {
        File directory = new File(activity.getCacheDir(), "runtimes");
        if (!directory.isDirectory() && !directory.mkdirs()) {
            throw new IllegalStateException("无法创建运行时缓存目录");
        }
        String id = module.getString("packageName");
        File target = new File(
            directory,
            id + "-" + module.getString("version") + ".apk"
        );
        if (target.isFile()
            && target.length() == module.getLong("size")
            && module.getString("sha256").equals(sha256(target))) {
            return target;
        }

        File temporary = File.createTempFile("runtime-", ".apk", directory);
        HttpURLConnection connection =
            (HttpURLConnection) new URL(module.getString("url")).openConnection();
        connection.setConnectTimeout(20_000);
        connection.setReadTimeout(180_000);
        connection.setInstanceFollowRedirects(true);
        try (InputStream input = connection.getInputStream();
             FileOutputStream output = new FileOutputStream(temporary)) {
            input.transferTo(output);
        } finally {
            connection.disconnect();
        }
        if (temporary.length() != module.getLong("size")) {
            throw new IllegalStateException("下载文件大小不匹配");
        }
        if (!module.getString("sha256").equals(sha256(temporary))) {
            throw new IllegalStateException("下载文件校验失败");
        }
        if (!temporary.renameTo(target)) {
            throw new IllegalStateException("无法保存运行时安装包");
        }
        return target;
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new java.io.FileInputStream(file)) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) {
                digest.update(buffer, 0, count);
            }
        }
        StringBuilder result = new StringBuilder();
        for (byte value : digest.digest()) result.append(String.format("%02x", value));
        return result.toString();
    }
}
