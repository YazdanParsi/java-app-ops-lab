package lab;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;

/** Normal "business" request that needs LOCK_A. After /freeze it blocks forever. */
@WebServlet("/work")
public class WorkServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        synchronized (Locks.LOCK_A) {
            resp.setContentType("text/plain");
            resp.getWriter().println("Work done");
        }
    }
}
