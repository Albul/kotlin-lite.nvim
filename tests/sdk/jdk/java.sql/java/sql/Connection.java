package java.sql;

public interface Connection extends AutoCloseable {
    boolean isClosed() throws SQLException;
}
