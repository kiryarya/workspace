import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.jar.*;

/** Compares class files or JARs using javap and creates a Markdown report. */
public final class ClassDiff {
    private static final List<String> FLAGS = Arrays.asList("-p", "-s", "-c", "-constants");

    public static void main(String[] args) {
        try {
            Config c = Config.parse(args);
            Map<String, View> before = inspect(c.before, c.javap);
            Map<String, View> after = inspect(c.after, c.javap);
            Result r = compare(before, after);
            Files.write(c.output, report(c, r).getBytes(StandardCharsets.UTF_8));
            System.out.println("Report: " + c.output.toAbsolutePath());
            System.out.println("Classes: +" + r.added.size() + " -" + r.removed.size()
                    + " changed=" + r.changed.size() + " unchanged=" + r.unchanged);
            System.exit(r.different() ? 1 : 0);
        } catch (IllegalArgumentException e) {
            System.err.println("Error: " + e.getMessage());
            System.err.println("Usage: ClassDiff [--javap PATH] [-o REPORT.md] BEFORE(.class|.jar) AFTER(.class|.jar)");
            System.exit(2);
        } catch (Exception e) {
            System.err.println("Error: " + e.getMessage());
            System.exit(2);
        }
    }

    private static Map<String, View> inspect(Path input, String javap) throws Exception {
        if (!Files.isRegularFile(input)) throw new IllegalArgumentException("File not found: " + input);
        String lower = input.getFileName().toString().toLowerCase(Locale.ROOT);
        Map<String, View> out = new TreeMap<String, View>();
        if (lower.endsWith(".jar")) {
            try (JarFile jar = new JarFile(input.toFile())) {
                Enumeration<JarEntry> entries = jar.entries();
                while (entries.hasMoreElements()) {
                    JarEntry e = entries.nextElement();
                    String n = e.getName();
                    if (e.isDirectory() || !n.endsWith(".class") || n.equals("module-info.class")
                            || n.startsWith("META-INF/versions/")) continue;
                    String className = n.substring(0, n.length() - 6).replace('/', '.');
                    out.put(className, runJavap(javap, Arrays.asList("-classpath", input.toString(), className)));
                }
            }
        } else if (lower.endsWith(".class")) {
            View v = runJavap(javap, Collections.singletonList(input.toString()));
            out.put(className(v.lines, input), v);
        } else throw new IllegalArgumentException("Only .class and .jar files are supported: " + input);
        return out;
    }

    private static View runJavap(String javap, List<String> target) throws Exception {
        List<String> cmd = new ArrayList<String>();
        cmd.add(javap); cmd.addAll(FLAGS); cmd.addAll(target);
        Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
        List<String> lines = new ArrayList<String>();
        try (BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = br.readLine()) != null) lines.add(line.replace("\r", "").replaceAll("\\s+$", ""));
        }
        int exit = p.waitFor();
        if (exit != 0) throw new IOException("javap failed (exit " + exit + "): " + String.join(" ", cmd)
                + "\n" + String.join("\n", lines));
        while (!lines.isEmpty() && lines.get(0).startsWith("Compiled from ")) lines.remove(0);
        return new View(lines, declarations(lines));
    }

    private static String className(List<String> lines, Path fallback) {
        for (String raw : lines) {
            String s = raw.trim();
            for (String kind : Arrays.asList(" class ", " interface ", " enum ")) {
                int at = s.indexOf(kind);
                if (at >= 0) {
                    String[] parts = s.substring(at + 1).split("\\s+");
                    if (parts.length > 1) return parts[1].replaceAll("[<{].*$", "");
                }
            }
        }
        String name = fallback.getFileName().toString();
        return name.substring(0, name.length() - 6);
    }

    private static SortedSet<String> declarations(List<String> lines) {
        SortedSet<String> out = new TreeSet<String>();
        for (int i = 0; i < lines.size(); i++) {
            String s = lines.get(i).trim();
            if (!s.endsWith(";") || s.startsWith("//") || s.startsWith("descriptor:")) continue;
            String descriptor = i + 1 < lines.size() && lines.get(i + 1).trim().startsWith("descriptor:")
                    ? " [" + lines.get(i + 1).trim() + "]" : "";
            out.add(s + descriptor);
        }
        return out;
    }

    private static Result compare(Map<String, View> a, Map<String, View> b) {
        Result r = new Result();
        SortedSet<String> names = new TreeSet<String>(); names.addAll(a.keySet()); names.addAll(b.keySet());
        for (String n : names) {
            if (!a.containsKey(n)) r.added.add(n);
            else if (!b.containsKey(n)) r.removed.add(n);
            else if (!a.get(n).lines.equals(b.get(n).lines)) r.changed.put(n, new Change(a.get(n), b.get(n)));
            else r.unchanged++;
        }
        return r;
    }

    private static String report(Config c, Result r) {
        StringBuilder b = new StringBuilder();
        b.append("# javap comparison report\n\n- Generated: `").append(OffsetDateTime.now()).append("`\n")
         .append("- Before: `").append(esc(c.before.toAbsolutePath().toString())).append("`\n")
         .append("- After: `").append(esc(c.after.toAbsolutePath().toString())).append("`\n")
         .append("- javap flags: `").append(String.join(" ", FLAGS)).append("`\n\n")
         .append("## Summary\n\n| Added | Removed | Changed | Unchanged |\n|---:|---:|---:|---:|\n|")
         .append(r.added.size()).append('|').append(r.removed.size()).append('|')
         .append(r.changed.size()).append('|').append(r.unchanged).append("|\n\n");
        classList(b, "Added classes", r.added); classList(b, "Removed classes", r.removed);
        if (!r.changed.isEmpty()) b.append("## Changed classes\n\n");
        for (Map.Entry<String, Change> e : r.changed.entrySet()) {
            SortedSet<String> added = new TreeSet<String>(e.getValue().after.declarations);
            added.removeAll(e.getValue().before.declarations);
            SortedSet<String> removed = new TreeSet<String>(e.getValue().before.declarations);
            removed.removeAll(e.getValue().after.declarations);
            b.append("### `").append(esc(e.getKey())).append("`\n\n");
            members(b, "Added declarations", added, "+"); members(b, "Removed declarations", removed, "-");
            b.append("<details><summary>Normalized javap output (before / after)</summary>\n\n")
             .append("#### Before\n\n```text\n").append(String.join("\n", e.getValue().before.lines)).append("\n```\n\n")
             .append("#### After\n\n```text\n").append(String.join("\n", e.getValue().after.lines)).append("\n```\n\n</details>\n\n");
        }
        if (!r.different()) b.append("No differences were found.\n");
        return b.toString();
    }

    private static void classList(StringBuilder b, String title, Collection<String> values) {
        if (values.isEmpty()) return;
        b.append("## ").append(title).append("\n\n");
        for (String v : values) b.append("- `").append(esc(v)).append("`\n");
        b.append('\n');
    }
    private static void members(StringBuilder b, String title, Collection<String> values, String sign) {
        if (values.isEmpty()) return;
        b.append("#### ").append(title).append("\n\n```diff\n");
        for (String v : values) b.append(sign).append(' ').append(v).append('\n');
        b.append("```\n\n");
    }
    private static String esc(String s) { return s.replace("`", "\\`"); }

    private static final class Config {
        Path before, after, output; String javap = "javap";
        static Config parse(String[] args) {
            Config c = new Config(); List<String> pos = new ArrayList<String>();
            for (int i = 0; i < args.length; i++) {
                if ((args[i].equals("-o") || args[i].equals("--output")) && i + 1 < args.length) c.output = Paths.get(args[++i]);
                else if (args[i].equals("--javap") && i + 1 < args.length) c.javap = args[++i];
                else if (args[i].startsWith("-")) throw new IllegalArgumentException("Unknown option: " + args[i]);
                else pos.add(args[i]);
            }
            if (pos.size() != 2) throw new IllegalArgumentException("Two input files are required");
            c.before = Paths.get(pos.get(0)); c.after = Paths.get(pos.get(1));
            c.output = c.output == null ? Paths.get("classdiff-report.md") : c.output;
            return c;
        }
    }
    private static final class View {
        final List<String> lines; final SortedSet<String> declarations;
        View(List<String> l, SortedSet<String> d) { lines = l; declarations = d; }
    }
    private static final class Change {
        final View before, after; Change(View b, View a) { before = b; after = a; }
    }
    private static final class Result {
        final SortedSet<String> added = new TreeSet<String>(), removed = new TreeSet<String>();
        final SortedMap<String, Change> changed = new TreeMap<String, Change>(); int unchanged;
        boolean different() { return !added.isEmpty() || !removed.isEmpty() || !changed.isEmpty(); }
    }
}
