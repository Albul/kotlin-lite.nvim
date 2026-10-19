package android.content;

/**
 * Proxying implementation of Context that simply delegates all of its calls to
 * another Context.
 */
public class ContextWrapper extends Context {
    Context mBase;

    @Override
    public String getPackageName() {
        return mBase.getPackageName();
    }
}
