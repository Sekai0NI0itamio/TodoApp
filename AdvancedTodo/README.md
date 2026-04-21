# AdvancedTodo — build instructions

This folder contains a single-file SwiftUI app. If you have Xcode installed, open an Xcode project and paste `Sources/main.swift` into a macOS SwiftUI app target.

If you only have the command-line tools, try building with the included script.

Terminal build (from workspace root):

```bash
cd "AdvancedTodo"
chmod +x build.sh
./build.sh
open AdvancedTodo.app
```

Notes:
- Building GUI macOS apps from the command line without Xcode can be fragile. If the terminal build fails, installing the full Xcode app or using a CI (GitHub Actions/macOS runner) is recommended.
