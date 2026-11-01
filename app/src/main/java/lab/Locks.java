package lab;

/** Two shared locks. FreezeServlet takes them in opposite order to create a deadlock. */
final class Locks {
    static final Object LOCK_A = new Object();
    static final Object LOCK_B = new Object();

    private Locks() {
    }
}
