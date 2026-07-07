pub fn mainSource() []const u8 {
    return
    \\package com.kira.app;
    \\
    \\import android.app.Activity;
    \\import android.os.Bundle;
    \\import android.util.Log;
    \\import android.widget.TextView;
    \\import java.io.BufferedReader;
    \\import java.io.InputStream;
    \\import java.io.InputStreamReader;
    \\import java.nio.charset.StandardCharsets;
    \\
    \\public final class MainActivity extends Activity {
    \\  private String runnerConfig() {
    \\    StringBuilder builder = new StringBuilder();
    \\    try (InputStream input = getAssets().open("KiraRunner.toml");
    \\         BufferedReader reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8))) {
    \\      String line;
    \\      while ((line = reader.readLine()) != null) {
    \\        builder.append(line).append('\n');
    \\      }
    \\      return builder.toString();
    \\    } catch (Exception error) {
    \\      return "KiraRunner.toml unreadable: " + error.getMessage();
    \\    }
    \\  }
    \\
    \\  public void onCreate(Bundle state) {
    \\    super.onCreate(state);
    \\    String config = runnerConfig();
    \\    Log.i("KiraRunner", "Kira Android runner host launched");
    \\    Log.i("KiraRunner", "Kira runner config loaded: " + config);
    \\    TextView label = new TextView(this);
    \\    label.setText("Kira runtime configured");
    \\    setContentView(label);
    \\  }
    \\}
    \\
    ;
}
