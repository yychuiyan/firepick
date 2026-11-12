package app.firepick.bridge;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.qrcode.QRCodeWriter;

import org.json.JSONObject;

public final class MainActivity extends Activity implements BridgeState.Listener {
    private TextView status;
    private TextView details;
    private ImageView pairingCode;
    private final java.util.Map<String, TextView> runtimeStatus = new java.util.HashMap<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setGravity(Gravity.CENTER_HORIZONTAL);
        int padding = Math.round(24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);

        TextView title = new TextView(this);
        title.setText("拾萤 Bridge");
        title.setTextSize(30);
        status = new TextView(this);
        status.setTextSize(19);
        details = new TextView(this);
        details.setTextSize(14);
        details.setTextIsSelectable(true);
        pairingCode = new ImageView(this);
        pairingCode.setAdjustViewBounds(true);
        pairingCode.setMaxHeight(Math.round(220 * getResources().getDisplayMetrics().density));

        layout.addView(title);
        layout.addView(status);
        layout.addView(pairingCode);
        layout.addView(details);
        addRuntimeInstaller(layout, "python");
        addRuntimeInstaller(layout, "nodejs");
        addRuntimeInstaller(layout, "thunder");
        addRuntimeInstaller(layout, "bdj");
        Button reset = new Button(this);
        reset.setText("撤销全部设备配对");
        reset.setOnClickListener(view -> {
            Intent intent = new Intent(this, BridgeService.class);
            intent.setAction(BridgeService.ACTION_RESET_PAIRINGS);
            startService(intent);
        });
        layout.addView(reset);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(layout);
        setContentView(scroll);
        BridgeState.get().addListener(this);
        startForegroundService(new Intent(this, BridgeService.class));
        render();
    }

    @Override
    protected void onDestroy() {
        BridgeState.get().removeListener(this);
        super.onDestroy();
    }

    @Override
    public void onChanged() {
        runOnUiThread(this::render);
    }

    private void render() {
        BridgeState state = BridgeState.get();
        status.setText(state.isRunning() ? "运行中" : "正在启动…");
        details.setText("地址：" + state.getAddress()
            + "\n证书指纹：" + state.getFingerprint()
            + "\n一次性配对码：" + state.getPairingCode()
            + "\n配对 URI：" + state.getPairingURI()
            + "\n\n已内置 QuickJS 与 Java/JAR Provider 运行时。");
        renderPairingCode(state.getPairingURI());
        renderRuntimeStatus();
    }

    private void renderPairingCode(String value) {
        try {
            int size = 720;
            var matrix = new QRCodeWriter().encode(
                value,
                BarcodeFormat.QR_CODE,
                size,
                size
            );
            int[] pixels = new int[size * size];
            for (int y = 0; y < size; y++) {
                for (int x = 0; x < size; x++) {
                    pixels[y * size + x] = matrix.get(x, y)
                        ? android.graphics.Color.BLACK
                        : android.graphics.Color.WHITE;
                }
            }
            Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            bitmap.setPixels(pixels, 0, size, 0, 0, size, size);
            pairingCode.setImageBitmap(bitmap);
        } catch (Exception error) {
            pairingCode.setImageDrawable(null);
        }
    }

    private void addRuntimeInstaller(LinearLayout layout, String id) {
        TextView state = new TextView(this);
        state.setTextSize(13);
        state.setText("配置中…");
        runtimeStatus.put(id, state);
        Button install = new Button(this);
        install.setText("安装 " + id + " 运行时");
        install.setOnClickListener(view -> {
            try {
                JSONObject module = loadModule(id);
                RuntimeInstaller.install(this, module, state::setText);
            } catch (Exception error) {
                state.setText("无法读取运行时配置");
            }
        });
        layout.addView(install);
        layout.addView(state);
    }

    private JSONObject loadModule(String id) throws Exception {
        try (java.io.InputStream input = getAssets().open("runtime-catalog.json")) {
            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            input.transferTo(output);
            return new JSONObject(output.toString("UTF-8")).getJSONObject(id);
        }
    }

    private void renderRuntimeStatus() {
        for (var entry : runtimeStatus.entrySet()) {
            try {
                JSONObject module = loadModule(entry.getKey());
                entry.getValue().setText(
                    RuntimeInstaller.isInstalled(this, module)
                        ? "已安装"
                        : "未安装 · " + module.getString("version")
                );
            } catch (Exception error) {
                entry.getValue().setText("状态未知");
            }
        }
    }
}

