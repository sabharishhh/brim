import BrimCore

extension ProjectBuildScanner {
    static let kinds: [Kind] = [
        Kind(markers: ["Cargo.toml"], artifacts: [
            Artifact(folder: "target", classification: .rebuildableOutput, restore: "cargo build")
        ], tool: "Rust"),
        Kind(markers: ["Package.swift"], artifacts: [
            Artifact(
                folder: ".build",
                classification: .dependencyStore,
                restore: "swift build. This also holds package checkouts; keep any local changes"
            )
        ], tool: "Swift"),
        Kind(markers: ["package.json"], artifacts: [
            Artifact(
                folder: "node_modules",
                classification: .dependencyStore,
                restore: "",
                lockFiles: [
                    "package-lock.json",
                    "npm-shrinkwrap.json",
                    "yarn.lock",
                    "pnpm-lock.yaml",
                    "bun.lockb",
                    "bun.lock"
                ]
            ),
            Artifact(
                folder: ".next",
                classification: .rebuildableOutput,
                restore: "the next Next.js build",
                dependency: "next"
            ),
            Artifact(
                folder: ".nuxt",
                classification: .rebuildableOutput,
                restore: "the next Nuxt build",
                dependency: "nuxt"
            ),
            Artifact(
                folder: ".svelte-kit",
                classification: .rebuildableOutput,
                restore: "the next SvelteKit build",
                dependency: "@sveltejs/kit"
            ),
            Artifact(
                folder: "node_modules/.astro",
                classification: .rebuildableCache,
                restore: "the next Astro build",
                dependency: "astro"
            ),
            Artifact(
                folder: ".angular/cache",
                classification: .rebuildableCache,
                restore: "the next Angular build",
                dependency: "@angular/cli"
            )
        ], tool: "Node"),
        Kind(markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], artifacts: [
            Artifact(folder: "build", classification: .rebuildableOutput, restore: "the next Gradle build"),
            Artifact(
                folder: ".gradle",
                classification: .dependencyStore,
                restore: "the next Gradle build. Cached dependencies may need the network"
            )
        ], tool: "Gradle"),
        Kind(markers: ["pubspec.yaml"], artifacts: [
            Artifact(folder: "build", classification: .rebuildableOutput, restore: "flutter build"),
            Artifact(
                folder: ".dart_tool",
                classification: .dependencyStore,
                restore: "flutter pub get, then a build",
                lockFiles: ["pubspec.lock"]
            )
        ], tool: "Flutter"),
        Kind(markers: ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg"], artifacts: [
            Artifact(
                folder: ".venv",
                classification: .stateful,
                restore: "your environment setup. A requirements file does not record every installed package "
                    + "or local change"
            ),
            Artifact(
                folder: "venv",
                classification: .stateful,
                restore: "your environment setup. A requirements file does not record every installed package "
                    + "or local change"
            ),
            Artifact(
                folder: ".pytest_cache",
                classification: .dependencyStore,
                restore: "the next pytest run. Test history and custom cached fixture values are lost"
            ),
            Artifact(folder: ".mypy_cache", classification: .rebuildableCache, restore: "the next mypy run"),
            Artifact(folder: ".ruff_cache", classification: .rebuildableCache, restore: "the next Ruff run")
        ], tool: "Python"),
        Kind(markers: ["Podfile"], artifacts: [
            Artifact(
                folder: "Pods",
                classification: .dependencyStore,
                restore: "pod install",
                lockFiles: ["Podfile.lock"]
            )
        ], tool: "CocoaPods"),
        Kind(markers: ["pom.xml"], artifacts: [
            Artifact(folder: "target", classification: .rebuildableOutput, restore: "mvn package")
        ], tool: "Maven"),
        Kind(markers: ["mix.exs"], artifacts: [
            Artifact(folder: "_build", classification: .rebuildableOutput, restore: "mix compile"),
            Artifact(
                folder: "deps",
                classification: .dependencyStore,
                restore: "mix deps.get, then mix compile",
                lockFiles: ["mix.lock"]
            )
        ], tool: "Elixir")
    ]
}
