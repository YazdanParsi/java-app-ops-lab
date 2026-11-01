package lab;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/** Deliberate memory leak: every call keeps another 10 MB alive. Used for the OOMKilled scenario. */
@WebServlet("/leak")
public class LeakServlet extends HttpServlet {
    private static final List<byte[]> HOLDER = new ArrayList<>();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        synchronized (HOLDER) {
            HOLDER.add(new byte[10 * 1024 * 1024]);
            resp.setContentType("text/plain");
            resp.getWriter().println("Leaked " + (HOLDER.size() * 10) + " MB so far");
        }
    }
}
