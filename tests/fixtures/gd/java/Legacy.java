package gd.java;

public class Legacy {
    public static final int LIMIT = 3;
    private String label;

    public Legacy(String label) {
        this.label = label;
    }

    public static Legacy of(String label) {
        return new Legacy(label);
    }

    public String label() {
        return label;
    }

    public enum Kind { SMALL, LARGE }
}
