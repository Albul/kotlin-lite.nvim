package autoimport.lib;

public class AiStatics {
    public static final int AI_LIMIT = 5;
    public int aiInstance = 0;

    public static int aiTwice(int x) {
        return x * 2;
    }

    public static class AiInner {
    }
}
