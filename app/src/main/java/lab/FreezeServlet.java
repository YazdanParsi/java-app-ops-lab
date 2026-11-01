package lab;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;

/**
 * Deliberate deadlock: thread 1 takes LOCK_A then LOCK_B, thread 2 takes LOCK_B then LOCK_A.
 * Both wait for each other forever. Used for the thread-dump scenario.
 */
@WebServlet("/freeze")
public class FreezeServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        new Thread(() -> lockBoth(Locks.LOCK_A, Locks.LOCK_B), "lab-deadlock-1").start();
        new Thread(() -> lockBoth(Locks.LOCK_B, Locks.LOCK_A), "lab-deadlock-2").start();
        resp.setContentType("text/plain");
        resp.getWriter().println("Deadlock started. Now call /app/work - it will hang.");
    }

    private static void lockBoth(Object first, Object second) {
        synchronized (first) {
            sleep(500); // give the other thread time to take its first lock
            synchronized (second) {
                System.out.println("This line is never printed");
            }
        }
    }

    private static void sleep(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
