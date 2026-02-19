policy "No hook bypass" do
  on :PreToolUse, tool: "Bash", match: /git\b.*--no-verify/
  gate "Cannot bypass git hooks."
end
