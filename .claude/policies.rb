policy "No hook bypass" do
  on :PreToolUse, tool: "Bash", match: /git\b.*--no-verify/
  gate "Cannot bypass git hooks."
end

policy "Background post commits" do
  on :PreToolUse, tool: "Bash", match: :git_commit
  transform command: "bin/background-post-commits.sh"
end
