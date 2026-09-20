import re
with open(".agent/task.md", "r") as f:
    c = f.read()

c = c.replace("- [ ] Perform FINAL M3 EXIT AUDIT after vulnerabilities fixed", "- [x] Perform FINAL M3 EXIT AUDIT after vulnerabilities fixed")
with open(".agent/task.md", "w") as f:
    f.write(c)
