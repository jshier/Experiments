# Homebrew formulae the Tools and the test-data generators use. Tools/doctor reports what's missing
# (`brew bundle check --verbose`); install them with `brew bundle --file Brewfile` when you choose to.

brew "llvm"        # llvm-mca, opt, llc (keg-only): Tools/mca, IR experiments
brew "jq"          # JSON: Tools/toolchain, counters, bench-table
brew "yq"          # mikefarah's yq: XML/YAML/TOML for Tools/counters, profile, remarks
brew "hyperfine"   # command-line benchmarking
brew "coreutils"   # gtimeout, gdate (ns), gnumfmt
brew "lz4"         # test-data's swift-help-lz4 generator
brew "xz"          # test-data's nativezip-lzma generator
brew "python"      # python3 3.14 or later: test-data's nativezip-formats and archive-coverage generators
brew "gh"          # GitHub: compiler bug searches, PRs
brew "shellcheck"  # linting the Tools
