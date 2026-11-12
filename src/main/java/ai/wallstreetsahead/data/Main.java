package ai.wallstreetsahead.data;

import com.azure.core.exception.HttpResponseException;
import io.modelcontextprotocol.json.McpJsonDefaults;
import io.modelcontextprotocol.server.McpServer;
import io.modelcontextprotocol.server.McpSyncServerExchange;
import io.modelcontextprotocol.server.transport.StdioServerTransportProvider;
import io.modelcontextprotocol.spec.McpSchema.CallToolRequest;
import io.modelcontextprotocol.spec.McpSchema.CallToolResult;
import io.modelcontextprotocol.spec.McpSchema.ServerCapabilities;
import io.modelcontextprotocol.spec.McpSchema.Tool;
import io.modelcontextprotocol.spec.McpSchema.ToolAnnotations;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.stream.Stream;

/**
 * MCP server (stdio) that fetches the ETF mover reports from an Azure file share into the local folder.
 * stdout carries the protocol, so nothing else may be printed there.
 */
public final class Main {

    private static final int MAX_LISTED = 500;
    private static final int MAX_FAILURES_SHOWN = 20;

    private final Config config = Config.fromEnv();
    private ShareSync sync;

    public static void main(String[] args) {
        new Main().start();
    }

    private void start() {
        McpServer.sync(new StdioServerTransportProvider(McpJsonDefaults.getMapper()))
                .serverInfo("wallstreetsahead-data", "0.2.1")
                .instructions("Fetches the ETF mover reports from Azure Files into the local data folder. "
                        + "Call check_new_data to see what is missing, then fetch_data to download it.")
                .capabilities(ServerCapabilities.builder().tools(true).build())
                // handle requests one at a time: the stdio transport drops replies that are sent concurrently
                .immediateExecution(true)
                .toolCall(tool("local_status",
                                "Show the local data folder: how many ETF folders it has and the newest date folder in each. "
                                        + "Does not contact Azure.",
                                Map.of(), true),
                        guarded(this::localStatus))
                .toolCall(tool("check_new_data",
                                "Compare Azure with the local folder and report which report files are missing or changed, "
                                        + "without downloading anything.",
                                filterProperties(), true),
                        guarded(this::checkNewData))
                .toolCall(tool("fetch_data",
                                "Download report files that are missing or changed locally. Never deletes local files. "
                                        + "By default only checks from a few days before the newest local date folder.",
                                filterProperties(), false),
                        guarded(this::fetchData))
                .toolCall(tool("list_remote",
                                "List the folders and files at one path in the Azure file share, relative to the configured root.",
                                Map.of("path", property("string", "Folder path, for example ETF_SPY or ETF_SPY/10-09-2026. Empty for the root.")),
                                true),
                        guarded(this::listRemote))
                .build();
    }

    // ---- tools ----

    private String localStatus(Map<String, Object> args) throws IOException {
        StringBuilder out = new StringBuilder();
        out.append("Local folder: ").append(config.localRoot()).append('\n');
        out.append("Azure share: ").append(config.shareName() == null ? "(not set)" : config.shareName());
        out.append(config.remoteRoot().isEmpty() ? "" : " / " + config.remoteRoot()).append('\n');
        out.append("API gateway: ").append(config.apiUrl() == null ? "(not set)" : config.apiUrl()).append('\n');
        out.append("API key: ").append(config.apiKey() == null ? "not set" : "set").append('\n');
        if (!Files.isDirectory(config.localRoot())) {
            return out.append("The local folder does not exist yet.").toString();
        }
        List<String> lines = new ArrayList<>();
        LocalDate newest = null;
        try (Stream<Path> children = Files.list(config.localRoot())) {
            for (Path p : children.filter(Files::isDirectory).sorted().toList()) {
                String name = p.getFileName().toString();
                if (!name.toUpperCase(Locale.ROOT).matches("ET[FE]_.+")) {
                    continue;
                }
                LocalDate date = ShareSync.newestLocalDate(p);
                lines.add("  " + name + ": " + (date == null ? "no date folders" : date));
                if (date != null && (newest == null || date.isAfter(newest))) {
                    newest = date;
                }
            }
        }
        out.append("ETF folders: ").append(lines.size()).append('\n');
        out.append("Newest local date folder: ").append(newest == null ? "none" : newest).append('\n');
        lines.forEach(l -> out.append(l).append('\n'));
        return out.toString();
    }

    private String checkNewData(Map<String, Object> args) throws Exception {
        ShareSync.Filter filter = filter(args);
        ShareSync.Plan plan = sync().plan(filter);
        return describe(plan, "to download").toString();
    }

    private String fetchData(Map<String, Object> args) throws Exception {
        ShareSync.Filter filter = filter(args);
        ShareSync.Plan plan = sync().plan(filter);
        StringBuilder out = describe(plan, "selected");
        if (plan.toDownload().isEmpty()) {
            return out.toString();
        }
        ShareSync.Result result = sync().download(plan);
        out.append("Downloaded: ").append(result.downloaded()).append(" files, ").append(megabytes(result.bytes())).append('\n');
        out.append("Failed: ").append(result.failures().size()).append('\n');
        result.failures().stream().limit(MAX_FAILURES_SHOWN).forEach(f -> out.append("  ").append(f).append('\n'));
        return out.toString();
    }

    private String listRemote(Map<String, Object> args) {
        String path = string(args, "path");
        List<ShareSync.Entry> entries = sync().list(path == null ? "" : path);
        StringBuilder out = new StringBuilder();
        out.append(entries.size()).append(" entries at '").append(path == null ? "" : path).append("'\n");
        entries.stream().limit(MAX_LISTED).forEach(e ->
                out.append(e.directory() ? "  [dir]  " : "  [file] ").append(e.name())
                        .append(e.directory() ? "" : "  (" + e.size() + " bytes)").append('\n'));
        if (entries.size() > MAX_LISTED) {
            out.append("  ... ").append(entries.size() - MAX_LISTED).append(" more not shown\n");
        }
        return out.toString();
    }

    // ---- helpers ----

    private StringBuilder describe(ShareSync.Plan plan, String label) {
        StringBuilder out = new StringBuilder();
        out.append("Top-level folders checked: ").append(plan.topFolders().size()).append('\n');
        out.append("Remote files checked: ").append(plan.remoteFilesChecked()).append('\n');
        out.append("Already current locally: ").append(plan.alreadyCurrent()).append('\n');
        out.append("Newest remote date folder in range: ")
                .append(plan.newestRemoteDate() == null ? "none" : plan.newestRemoteDate()).append('\n');
        out.append("Files ").append(label).append(": ").append(plan.toDownload().size())
                .append(" (").append(megabytes(plan.totalBytes())).append(")\n");
        plan.countByDate().forEach((date, count) -> out.append("  ").append(date).append(": ").append(count).append(" files\n"));
        return out;
    }

    private synchronized ShareSync sync() {
        String missing = config.missingApiSettings();
        if (missing != null) {
            throw new IllegalStateException(missing);
        }
        if (sync == null) {
            sync = new ShareSync(config);
        }
        return sync;
    }

    private static ShareSync.Filter filter(Map<String, Object> args) {
        return new ShareSync.Filter(string(args, "etf"), date(args, "since"), date(args, "until"),
                Boolean.TRUE.equals(args.get("full")));
    }

    private static Map<String, Object> filterProperties() {
        Map<String, Object> props = new LinkedHashMap<>();
        props.put("etf", property("string", "Limit to one ETF, for example SPY or XLK. Omit for all ETFs."));
        props.put("since", property("string", "Earliest date folder to check, as YYYY-MM-DD. "
                + "Omit to start a few days before the newest local date folder."));
        props.put("until", property("string", "Latest date folder to check, as YYYY-MM-DD. Omit for no upper limit."));
        props.put("full", property("boolean", "Check every date folder back to the start. Slow; use to repair gaps."));
        return props;
    }

    private static Map<String, Object> property(String type, String description) {
        return Map.of("type", type, "description", description);
    }

    private static Tool tool(String name, String description, Map<String, Object> properties, boolean readOnly) {
        Map<String, Object> schema = new LinkedHashMap<>();
        schema.put("type", "object");
        schema.put("properties", properties);
        return new Tool.Builder()
                .name(name)
                .description(description)
                .inputSchema(schema)
                .annotations(new ToolAnnotations(null, readOnly, false, true, !name.equals("local_status"), null))
                .build();
    }

    @FunctionalInterface
    private interface Handler {
        String run(Map<String, Object> args) throws Exception;
    }

    /** Turns any failure into an error result the model can read, instead of breaking the connection. */
    private static BiFunction<McpSyncServerExchange, CallToolRequest, CallToolResult> guarded(Handler handler) {
        return (exchange, request) -> {
            try {
                Map<String, Object> args = request.arguments() == null ? Map.of() : request.arguments();
                return new CallToolResult.Builder().addTextContent(handler.run(args)).build();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return error("Interrupted");
            } catch (Exception e) {
                // listing runs on worker threads, so the gateway's answer can arrive wrapped
                for (Throwable t = e; t != null; t = t.getCause()) {
                    if (t instanceof HttpResponseException http) {
                        return error(gatewayMessage(http));
                    }
                }
                String message = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                return error(message.lines().findFirst().orElse(message));
            }
        };
    }

    /** The gateway answers 401/403/429 for key problems; say what they mean rather than echo the raw response. */
    private static String gatewayMessage(HttpResponseException e) {
        int status = e.getResponse() == null ? 0 : e.getResponse().getStatusCode();
        return switch (status) {
            case 401 -> "The API key was rejected (401). Check the key set for the plugin is current, then restart Claude.";
            case 403 -> "The API key is not allowed to read this data (403). Ask the administrator to check the key's subscription.";
            case 429 -> "The API key's usage limit was reached (429). Wait and try again, or ask the administrator to raise it.";
            default -> {
                String message = e.getMessage() == null ? "HTTP " + status : e.getMessage();
                yield message.lines().findFirst().orElse(message);
            }
        };
    }

    private static CallToolResult error(String message) {
        return new CallToolResult.Builder().addTextContent("Error: " + message).isError(true).build();
    }

    private static String string(Map<String, Object> args, String key) {
        Object value = args.get(key);
        return value == null || value.toString().isBlank() ? null : value.toString().trim();
    }

    private static LocalDate date(Map<String, Object> args, String key) {
        String value = string(args, key);
        if (value == null) {
            return null;
        }
        try {
            return LocalDate.parse(value);
        } catch (DateTimeParseException e) {
            throw new IllegalArgumentException("'" + key + "' must be a date as YYYY-MM-DD, got: " + value);
        }
    }

    private static String megabytes(long bytes) {
        return String.format(Locale.ROOT, "%.1f MB", bytes / 1_048_576.0);
    }
}
