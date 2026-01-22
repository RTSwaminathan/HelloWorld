package hello;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpExchange;
import java.net.InetSocketAddress;
import java.io.OutputStream;
import java.time.LocalTime;
import java.nio.charset.StandardCharsets;

public class HelloWorld {
  public static void main(String[] args) throws Exception {
    int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "5000"));

    HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);

    server.createContext("/", (HttpExchange ex) -> {
      StringBuilder body = new StringBuilder();
      body.append("The current local time is: ").append(LocalTime.now()).append("\n");

      try {
        Greeter greeter = new Greeter();
        body.append(greeter.sayHello()).append("\n");
      } catch (Throwable t) {
        body.append("Greeter error: ").append(t.getMessage()).append("\n");
      }

      byte[] resp = body.toString().getBytes(StandardCharsets.UTF_8);
      ex.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
      ex.sendResponseHeaders(200, resp.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(resp);
      }
    });

    server.setExecutor(java.util.concurrent.Executors.newCachedThreadPool());
    server.start();
    System.out.println("Listening on port " + port);
  }
}
