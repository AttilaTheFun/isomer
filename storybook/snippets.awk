# Copies each story's source (stories/*.swift, between a "// story: <id>"
# line and an "// end story" line) into StorySnippets.swift's table, as raw
# string literals: the code a story's page shows is the code it runs.
BEGIN {
    print "// Generated from stories/*.swift by snippets.awk (BUILD.bazel's :snippets)."
    print ""
    print "let storySnippets: [String: String] = ["
}
/^\/\/ story: / { id = $3; inside = 1; body = ""; next }
/^\/\/ end story/ { printf "    \"%s\": ##\"\"\"\n%s\"\"\"##,\n", id, body; inside = 0; next }
inside { body = body $0 "\n" }
END { print "]" }
